# protocol-change/051: an opt-in web view on the daemon's listener

**Status**: ACCEPTED, IMPLEMENTED in #552 (2026-09-27) · **Affects**: Part 1.6 client protocol
(the listener's route table, the control `hello`, one control command) ·
**Raised by**: issue #530, phase 4 · **Decision record**:
[ADR-014](../docs/adr/014-second-runtime.md)

## Problem

Phase 4 of issue #530 proves that the client engine the terminal runs can
drive a second view: a read-only page in a browser, rendered by a Lustre
server component inside `loomd`. The engine is `packages/session_view`, the
session lane and transcript projection extracted from `packages/tui`
(ADR-013, phase 4 addendum). The page is a skeleton. It shows the
transcript lines of one session, picked by its ID, and nothing else.
Later phases build it out into an agent-first, multi-agent view with
cross-session messaging (ADR-014, "Direction").

Part 1.6 says one listener carries exactly two authenticated endpoints,
`/v2/control` and `/v2/sessions/<id>/ws`, and every other path is a 404.
Serving the page needs more routes on that listener, and a browser cannot
authenticate the way a terminal does:

- A terminal sends `Authorization: Bearer <credential>` on the upgrade. A
  browser's WebSocket API cannot set that header, and a bearer placed in a
  page, a URL or browser storage is readable by anything that can read
  those.
- The daemon's owner credential authorizes every session and every
  lifecycle command. It must never reach a browser.
- A page served from `127.0.0.1` can be reached by any other page the same
  browser loads, including through DNS rebinding, so the loopback bind
  that protects the WebSocket endpoints does not protect a page.

This proposal adds the routes, the way a person's browser proves who the
person is, and the flag that turns all of it on. With the flag off,
nothing in Part 1.6 changes.

## What was considered

### Where the component gets session traffic

**Loopback.** The component opens `/v2/sessions/<id>/ws` on its own
listener with `host/websocket`, exactly as a terminal does, and the lane
runs over it unchanged. This changes no interface, but it needs a
plaintext bearer inside the daemon to put in the upgrade header. The
daemon stores only credential digests (`storage/access`), so the browser
would have to hand the component the person's bearer, or the daemon would
have to mint a bearer for every page. The first puts the credential in the
browser, which this proposal exists to prevent. The second creates a new
kind of credential with its own rotation and revocation.

**The legacy in-process hook, `gateway.attach`.** It registers an
anonymous sink with no principal and no role, and it speaks the host
fixture's dialect: one unbounded `snapshot` event, with `snapshot_next`,
`escalations_get` and `history` refused. The lane speaks the bounded
transfer, so it cannot run over this hook, and an anonymous attachment has
no role for the gateway to enforce.

**The authenticated in-process attach, chosen.** `/v2/sessions/<id>/ws`
already does its work in two halves. `client/daemon/server` authenticates
the upgrade and resolves a `server.Attachment` (principal, authority,
incarnation, permit, registry), and `client/daemon/session_socket` attaches
that to the gateway with `gateway.attach_authenticated_flushing`, which
speaks the full v2 dialect and re-checks membership on every request
and every push through its `check` capability. The web route reuses both
halves. It resolves the same `Attachment` from the browser's session
credential (below) instead of from a bearer header, and a small relay
process attaches it to the gateway the way `session_socket` does. The
gateway's interface does not change, and neither does the session
protocol: the relay carries the same v2 frames a socket would.

Neither in-process option changes a frozen interface beyond the routes
themselves, so the choice rests on authentication. The authenticated
attach is the only one that needs no bearer inside the daemon and gives
the gateway a principal and a role to enforce.

### How a browser proves who it is

A bearer in a query string was rejected: it lands in browser history,
proxy logs and the `Referer` header. A bearer typed into the page and kept
in browser storage was rejected: any script on the page's origin can read
it, and it authorizes the person's every session.

The chosen shape is a one-time link exchanged for a cookie. The person's
own `loom` client, which already holds the person's credential, asks the
daemon for a link over the control connection. The daemon returns a
single-use ticket that stands for that principal and that session only.
The browser presents the ticket once, and the daemon exchanges it for an
`HttpOnly` cookie that no script can read. The credential itself never
leaves `loom`.

### How `loom --ui` learns whether the running daemon serves the view

`loom --ui` may find a daemon already running. It could probe the route
over HTTP and read a 404 as "off", or read a field the daemon states. The
probe needs an HTTP client in the terminal and interprets an error as an
answer. A field in the authenticated control `hello` is read on the
connection `loom` already opens, and the daemon states it rather than the
terminal guessing it.

## Proposal

### Gating

`loomd --ui` turns the view on for the life of the daemon. Without the
flag:

- `server.handle` routes exactly `/v2/control` and `/v2/sessions/<id>/ws`,
  and every `/ui/...` path is a 404, as today.
- The control `hello` carries no `ui` field.
- The control command `ui.link` is refused with `unavailable`.

`loom --ui --session <id>` resolves the daemon through the existing
discovery path (`tui/daemon/bootstrap.resolve`, under `launch.lock`).

- **No daemon is running.** `loom` adds `--ui` to the launch arguments it
  already passes (`bootstrap.Launch.arguments`), so the daemon it starts
  serves the view.
- **A daemon is running and its `hello` names `ui`.** `loom` opens the
  session if it is not resident (`sessions.open`, as a terminal does),
  requests a link for it and prints the URL. It does not open a browser;
  the person opens the printed link.
- **A daemon is running and its `hello` does not name `ui`.** `loom`
  prints that the running daemon was started without `--ui`, and that
  stopping it and running `loom --ui` again starts one that serves the
  view. It exits with status 1. It does not stop, replace or relaunch a
  running daemon, because other people's terminals may be attached to it.

### The control `hello`

The body gains one optional field, present only when the view is on:

```
"ui": {"path": "/ui"}
```

A client that does not know the field ignores it. `path` is the route
prefix, stated so that a later change can move it without a client
guessing.

### The control command `ui.link`

```
c→s: {v:2, id, cmd:"ui.link", body:{session_id:<canonical-session-id>}}
s→c: {v:2, reply_to, event:"ui.link",
      body:{path:"/ui/sessions/<id>?ticket=<ticket>", expires_in_ms:<int>}}
```

The daemon checks the caller's session membership exactly as a
`/v2/sessions/<id>/ws` upgrade does (`manager.session_authority`), and
refuses with `forbidden` otherwise. The ticket is 32 bytes from OTP's
`crypto:strong_rand_bytes`, through `broker/token.production_entropy`, the
source invitations already use, and is sent base16 encoded. The daemon
keeps only its SHA-256 digest, together with the principal, the session
and the digest of the credential that asked for it. `expires_in_ms` is a
duration, the ticket's remaining lifetime in milliseconds (60,000 when
issued), not an instant, so the client needs no clock agreement with the
daemon. The reply carries a path, not a full URL; `loom` joins it to the
address it discovered.

### Routes

Present only with `--ui`. `<id>` is a canonical session ID, parsed with
`ids.parse_session_id` before anything else happens.

| Method and path | Purpose |
|---|---|
| `GET /ui/sessions/<id>?ticket=<t>` | Exchange a ticket for a cookie, and answer with a same-origin page that moves to `/ui/sessions/<id>`. |
| `GET /ui/sessions/<id>` | The page: a shell holding one `<lustre-server-component>` whose route is the socket below. |
| `GET /ui/sessions/<id>/ws` | WebSocket upgrade for the Lustre transport. One server component per connection. |
| `GET /ui/assets/<name>` | Lustre's client runtime (served from the `lustre` application's `priv` directory), the page's stylesheet, and the exchange page's script. A fixed list; any other name is a 404. |

The session ID is in every per-session path. A later page that shows
several sessions or agents mounts one `<lustre-server-component>` per
view, each with its own `/ui/sessions/<id>/ws` route, and so its own
component keyed by the person and that session.

### Tickets and UI sessions

One `weft/actor` owns two tables: tickets and UI sessions. Every mint,
redemption and lookup is a call to it, so redemption is serialized: two
mist handlers that present the same ticket at once reach the actor one
after the other, the first removes the ticket and the second finds
nothing. Each table is a per-key deadline table inside that one actor,
which `docs/weft.md` ("Per-key deadline tables stay") allows, and
`actor.periodic` sweeps both every 60 seconds. A lookup also checks the
expiry itself, so the sweep only reclaims memory and is not what enforces
a deadline.

- **A ticket** lives 60 seconds and can be redeemed once.
- **A UI session** lives 8 hours from the exchange, however it is used.
  That is a working day: long enough that a page left open for a day's
  work keeps working, short enough that a cookie copied out of a browser
  stops working the same day. Renewing it costs one `loom --ui`. The
  cookie carries no `Max-Age`, so the browser also drops it when the
  browser session ends.

Redeeming a ticket creates a new UI session bound to the ticket's
principal, session and minting credential digest, and returns a new
cookie. If the request already carries a `loom_ui` cookie, that UI session
is deleted first. A ticket replaces the UI session outright; nothing is
merged. A UI session grants exactly one session, the ticket's.

The cookie is `loom_ui`: 32 random bytes from the same source, base16
encoded, with `HttpOnly`, `SameSite=Strict` and `Path=/ui`. The daemon
keeps only its SHA-256 digest. UI sessions live in memory and end with the
daemon.

### Checks on every `/ui` request

In this order, each refusal ending the request:

1. **Host.** `Host` is a loopback name (`127.0.0.1`, `[::1]` or
   `localhost`) with any port. The listener binds only loopback, and a
   browser reaching it through a local forward (for example `ssh -L`)
   presents the forward's port. A rebinding attack presents its own host
   name. Otherwise `403`.
2. **Ticket exchange only: `Sec-Fetch-Site`** is `none` (a link pasted or
   opened from outside a browser page) or `same-origin`. A top-level
   navigation sends no `Origin`, so `Origin` cannot be required here. The
   ticket is the CSRF secret: a cross-site page cannot know a ticket, and
   this check refuses the exchange when another site drives the browser
   to a ticket it somehow learned. Otherwise `403`.
3. **WebSocket upgrade only: `Origin`** is present and equals `http://`
   followed by the request's `Host`. Browsers always send `Origin` on a
   WebSocket upgrade. Otherwise `403`.
4. **Cookie** (every route except the exchange and the assets). The
   cookie's digest names a live UI session, whose session is the one in
   the path. Otherwise `401`.
5. **Credential.** The UI session's minting credential digest still
   authenticates (`manager.authenticate`), and its principal is still a
   member of the session (`manager.session_authority`). A revoked or
   rotated credential therefore ends every UI session it created.
   Otherwise `401` or `403`.

The upgrade then acquires a parser permit with `root.acquire`, like any
session socket, so the page counts against `max_connections` and the
reserved-byte limit. After admission the gateway's `check` capability
re-authorizes every request and every push with the same call a terminal
socket makes, `manager.frame_authority` (`session_socket.authorize`),
given the minting credential's digest. A credential or membership revoked
while a page is open therefore stops its pushes and closes it.

The daemon's owner credential never reaches a browser. The browser holds
a ticket for at most 60 seconds and then a cookie. Both are random values
the daemon generated; neither is derived from a credential, and neither
authenticates anywhere but `/ui`.

### Response headers

Every `/ui` response carries:

```
Content-Security-Policy: default-src 'none'; script-src 'self';
  style-src 'self'; style-src-attr 'unsafe-inline';
  connect-src 'self' ws://<Host>; img-src 'self';
  base-uri 'none'; form-action 'none'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Cache-Control: no-store
```

The page's stylesheet is a `<link>` to `/ui/assets/web_view.css`, and its
scripts are files under `/ui/assets`, so no inline script or `<style>`
element is needed. `style-src-attr 'unsafe-inline'` is there because
Lustre's client runtime applies a `style` attribute by setting it, which
a policy without it would refuse; the skeleton's view sets none, and the
allowance covers attributes only, never a stylesheet. `connect-src` names
the WebSocket origin explicitly as well as `'self'`, for browsers that do
not map `'self'` onto `ws:`.

The exchange answers `200` with a same-origin page whose script
(`/ui/assets/web_view_enter.js`) runs `location.replace(location.pathname)`.
A `303` would carry the cookie's first use on the redirect of a
navigation that started on another site, where a `SameSite=Strict` cookie
is not sent, so a link clicked from a cross-site page would land on a
`401`. The page's own navigation is same-origin, so the cookie is sent,
and `replace` keeps the ticket URL out of the history.

### Read-only enforcement

Two independent layers. Either one alone keeps the page from mutating.

- **In the daemon, by role.** In this phase the relay's gateway `Binding`
  carries `access.Participant(access.Observer)` whatever the principal's
  membership is, and its `check` caps the resolved authority to the same.
  The gateway refuses every command outside its `read_only` list for an
  observer, so a mutation frame from the relay is refused however it was
  produced.
- **In the component, by type.** The component's message type is the
  lane's arrivals and a tick, plus nothing else, and its view attaches no
  event handlers. Lustre dispatches a browser event only to a handler
  present in the rendered tree, so a browser has nothing to send. The
  component calls no `session_channel.submit`.

When a later phase lets an operator mutate from the page, it removes the
cap wholesale, so the role on the binding is the principal's membership
role and nothing else. It does not add a second role source such as a
ticket scope; the daemon's membership record stays the one place a
person's authority is decided.

### The relay

One process per page socket, in `packages/client`, built on `weft/actor`.
It plays the part `session_socket` plays for a terminal. It holds the
authenticated attachment and attaches to the gateway with
`attach_authenticated_flushing`, giving its own pid as the `socket`, so
the gateway monitors the relay and removes the attachment and its
presence when the relay exits. A frame the lane transmits becomes one
bounded `gateway.connection_request`, whose reply goes to the component
as `connection_event.Incoming`; a frame the gateway pushes arrives on the
sink and goes to the component the same way. One mailbox serializes both,
as in `session_socket`, so a reply and a push never interleave.

The relay ends in exactly four ways, and each leaves no process and no
presence behind:

- **`Shut`.** The lane closes its socket: the relay detaches from the
  gateway and exits.
- **The browser goes away.** The mist socket closes and shuts the
  component down. The relay monitors the component, detaches on its
  `DOWN` and exits.
- **The gateway goes away** (the session stops, or the daemon shuts
  down). The relay monitors the gateway connection's pid, as
  `session_socket` does with `GatewayDown`, tells the page's socket to
  close, and exits.
- **The gateway closes the attachment** (a check refused, for example on
  revocation). The gateway calls the attachment's `close`, which reaches
  the relay; the relay tells the page's socket to close and exits, and
  the socket's close shuts the component down.

Backpressure is the terminal socket's: the relay's and the component's
mailboxes are unbounded, and what bounds a slow browser is the mist
socket's TCP writes, as for a terminal attached over `session_socket`.

The component is the lane's host. Its socket handle type is the relay's
subject, and its `Transmit`/`Shut` interpreter has the terminal's shape
(`tui/terminal_lane.perform`): transmit writes to the relay, shut detaches
it. Later mutations therefore arrive as more `Transmit`s from
`session_channel.submit`, not as a new effect.

### Dependencies

Two new third-party packages, in a new package `packages/web_view` that
holds the component and the view, and through it in `packages/client`:

- `lustre == 5.7.1` (MIT). Its dependencies are `gleam_erlang`,
  `gleam_otp`, `gleam_json`, `gleam_stdlib` and `exception`, which the
  daemon already has, and `houdini`.
- `houdini == 1.2.1` (Apache-2.0), Lustre's HTML escaping.

The page's WebSocket runs on the daemon's existing `mist` fork
([ADR-011](../docs/adr/011-bounded-websocket-forks.md)), whose frame
bounds apply to it. `web_view` ships inside the daemon's release because
`client` depends on it; there is no separate artifact for it.

## Impact

- `client/daemon/main`: parses `--ui`, starts the ticket actor, and passes
  the view's configuration to the router.
- `client/daemon/server`: routes `/ui/...` when on; adds `ui.link` and the
  `hello` field.
- `packages/client`: the ticket actor, the `/ui` request checks, the
  relay, and the Lustre socket handler that registers each browser
  connection with its component.
- `packages/web_view` (new): the component, its model, update and view,
  over `session_view`, and the page and asset content.
- `packages/tui`: `--ui`, the `hello` field, `ui.link`, and the message
  when the running daemon lacks the view.
- `docs/client-protocol.md` and spec Part 1.6: the conditional routes, the
  `hello` field and `ui.link`.

## Cost

- Part 1.6's statement that the listener has two endpoints becomes "two,
  and with `--ui` the `/ui` routes as well".
- The daemon grows an HTTP surface that serves a page, and with it the
  class of browser attacks this proposal defends against. The flag keeps
  it off by default.
- **The cookie is shared with every other service on loopback.** Browsers
  scope cookies by host and ignore the port, so a same-site navigation to
  any `127.0.0.1` port under `/ui/...` sends `loom_ui` to whatever listens
  there, and a program that is not a browser can present a stolen cookie
  with any `Origin` it likes. What such a holder gets is capped: observer
  access to the one session the ticket named, for at most 8 hours, and
  only until the minting credential or the membership is revoked. A
  session's own tool processes can reach the listener only as far as the
  sandbox's network policy lets them (`--network`, whose default is full
  access); `--network off` keeps them off loopback, and with it off any
  `/ui` route. A tool still holds no cookie unless it can read the
  browser's profile, which the read scope decides.
- Two more third-party packages ship in the daemon, used only with `--ui`.
- UI sessions are in memory. A daemon restart ends every open page, and
  the person runs `loom --ui` again.
- The skeleton caps every page to observer. A person with operator rights
  sees a read-only page until a later phase lifts the cap.

## Decision

**Proposed.** Serve the view from `loomd` behind `--ui`, with its traffic
through the gateway's authenticated in-process attach and its browser
authenticated by a single-use ticket exchanged for a cookie. Loopback was
rejected because it needs a plaintext bearer inside the daemon, and the
legacy `gateway.attach` because it has no role and speaks a dialect the
lane cannot. A bearer in the page was rejected because it would put a
credential that authorizes every one of the person's sessions where any
script on the page could read it. The ticket costs one control command
and an in-memory table, and in exchange the only secrets a browser ever
holds are daemon-generated, scoped to one session, capped to observer,
and short-lived.

## Open

- **Remote access.** A person reaching a remote daemon through a TLS
  endpoint would present a non-loopback `Host`, which this proposal
  refuses. Allowing it needs a configured allowed origin and the `Secure`
  cookie attribute, and is left to the phase that needs it.
- **Opening the browser.** `loom --ui` prints the link. Opening it needs a
  platform command (`open`, `xdg-open`), and is deferred until that is
  decided.
- **A default session.** `loom --ui` takes `--session`. Choosing the
  session a terminal would attach to when it is omitted is left for later.

## Addendum: operators act from the page (2026-09-26)

**Status**: ACCEPTED, IMPLEMENTED in #554 (2026-09-27) · **Raised by**: issue #530, the web view's first
interactive milestone ([ADR-014](../docs/adr/014-second-runtime.md),
"Direction")

The first interactive milestone gives the page a composer and approval
buttons. It has two commands. `Submit(text)` sends a prompt, or a steer, to
the addressed strand. `Decide(approval, choice)` answers one pending
escalation. Both reach the gateway as the same v2 frames a terminal sends,
encoded by the same engine code (`session_view/operator`, over
`session_channel.submit`). The proposal above caps every page to observer and
says a later phase "removes the cap wholesale". This addendum records what
replaces the cap and what else changes because a page can now act.

Everything here applies only with `loomd --ui`. An observer's page shows
what it shows today and can send nothing, as today. Its address moves under
a page key (below), because every page has one cookie shape.

### What a page is worth now

The proposal above prices a stolen `loom_ui` cookie at "observer access to
the one session the ticket named". An operator's page is worth more. It can
send prompts that run tools, and it can approve escalations. An escalation
is the check a person makes before an agent gets more authority than its
policy gives it. So the threat that matters most is the session's own agent
getting control of an operator's page and answering its own escalations.
Rule Zero says an agent must never reach that. The agent's tools can reach
the loopback listener unless the session runs with `--network off`. The
agent can also put text in front of the person: in the transcript, in a
file, or in a URL it asks the person to open.

Four ways an attacker could act through an operator's page, and what stops
each:

1. **Send commands through the person's browser.** A page on another site,
   or on another loopback port, opens a WebSocket to the daemon or submits
   a form to it. See "Commands over the socket".
2. **Take the cookie and act without the browser.** A program that holds
   the cookie can send any `Origin` it likes, because only browsers enforce
   `Origin`. See "Three secrets, three scopes".
3. **Run script inside the page.** Script on the page's own origin drives
   the socket the way the person would. See "Nothing from the session
   becomes markup".
4. **Trick the person into approving.** Text the agent wrote is made to
   look like the approval card, or placed where a keystroke meant for the
   composer lands on a button. See "The approval card".

### The page's role

The role an operator's page acts with is the smallest of three things:

- **The membership record.** It is the only source of grants. Nothing below
  adds authority the record does not hold.
- **The page's ceiling, chosen when the link is minted.** `loom --ui` asks
  for an observer page. `loom --ui --operate` asks for an operator page. The
  control command carries the choice:

  ```
  c→s: {v:2, id, cmd:"ui.link", body:{session_id:<id>, page:"operator"}}
  ```

  `page` is `"observer"` (the default when the field is absent) or
  `"operator"`. Any other value is refused with `bad_request`. The ticket, and
  the UI session it becomes, record the ceiling. A ceiling is a cap and not
  a grant. An observer who asks for an operator page gets an observer page.
- **Operator, always.** No page ever carries `Owner`. The gateway gives an
  owner one thing an operator lacks within a session, the worktree bytes,
  and a page never needs them.

So without `--operate`, even an owner or operator gets an observer page.
With it, an operator or owner gets an operator page, and an observer still
gets an observer page.

The relay attaches with that smallest role, and its `check` answers with
the same minimum computed from the current membership record. The gateway
already calls `check` at every request and every push
(`gateway.check_binding`). It refuses the frame unless the principal and
the authority equal the binding's. So any change to the capped role closes
the attachment at the next frame. The same goes for a revoked credential, a
removed membership, or an ended UI session (`ui_relay.while_open`). The
page never changes role while it is open. Its socket closes, and a reload
admits a page for whatever the record and the ceiling now allow.

The permit class follows the capped role, as it does for a terminal. The
page socket's inbound frame limit stays at 64 KiB for an observer's page. It
is 1 MiB for an operator's page, not the terminal's 32 MiB. The page sends
Lustre events, and this milestone's largest is a text prompt. Pasted images,
which are what need the terminal's limit, are not in this milestone.

### Two components, chosen by role at admission

The page socket starts one of two Lustre applications. It chooses from the
capped role it admitted:

- **The observer component** is today's component (`web_view/component`).
  Its message type has no command constructor, and its view attaches no
  event handler. Where an operator's page has its composer, it draws one
  fixed line saying the page is read-only. The browser has nothing it can
  send, and the page socket drops every browser message before it reaches
  the component.
- **The operator component** (`web_view/operator_page`) wraps the
  observer's messages and adds `Submitted(text, delivery)` and
  `Decided(id, seq, answer)`. Its view adds the composer, an uncontrolled
  form whose draft the browser keeps until it is submitted, and the
  approval cards, with their handlers. `delivery` is a prompt, or a steer
  while the strand is running; the page socket forwards only the `click`
  and `submit` events those handlers attach.

The daemon's gateway refuses a mutation from an observer binding however
the frame was produced, as it does today. The component's type is the
second layer. An observer's component cannot produce a command, and no
message can widen its type while it runs. Either layer alone refuses an
observer's command, and each is tested on its own.

### Commands over the socket

A command reaches the daemon only as a Lustre event on an established page
socket. No HTTP route performs a command. Every route is a `GET`, and the
policy's `form-action 'none'` refuses a form submission from the page.
Opening the socket needs all of these, and a page from another origin can
supply none of them:

- **`Origin` equal to `http://` followed by the request's `Host`, port
  included** (`ui_http.origin_matches`). A page on another loopback port is
  same-site for cookies but not same-origin. The browser sends that page's
  own origin, which does not match, so the upgrade is refused.
- **The `loom_ui` cookie.** It is `SameSite=Strict`, so a cross-site page
  cannot make the browser send it.
- **The page nonce** (below). Script on another origin cannot read it.

The keyed page itself, `GET /ui/p/<key>/sessions/<id>`, also requires
`Sec-Fetch-Site` to be `same-origin` (the exchange page's move, or a
reload) or `none` (a link opened from outside the browser, or a bookmark).
A missing header, `same-site` or `cross-site` is refused with `403`. So a
page on another loopback port cannot navigate the browser to the keyed page,
or load it in a way that would put the page in front of the person under
another page's control.

Inside the socket, Lustre dispatches a browser event only to a handler in
the tree the component rendered. A frame that does not decode is dropped, and
each handler's payload is decoded by a total decoder. So a forged event can
name only a control the person's own page shows. `frame-ancestors 'none'`
stays, so no other page can frame the composer or the approval buttons and
trick a click onto them.

### Three secrets, three scopes

Browsers scope cookies by host and path, not by port. The proposal above
records the consequence: any program listening on another loopback port
receives `loom_ui` when the browser requests a matching path there. For an
observer's cookie that was an accepted cost. For an operator's, it would let
the agent take the page. The agent starts a server on a loopback port,
prints a link to it, and waits for the person to open the link. A navigation
opened from outside the browser counts as same-site, so the cookie goes too.

So a page stands on three secrets, each scoped differently. All three are
32 random bytes, base16 encoded, from `crypto:strong_rand_bytes` through
`broker/token.production_entropy`. The daemon keeps only their SHA-256
digests, with the UI session.

- **The cookie** is minted at the exchange, as before. Its path is now the
  page key's: `Path=/ui/p/<key>`.
- **The page key** is minted at the exchange and is part of the page's
  address: `/ui/p/<key>/sessions/<id>` and `/ui/p/<key>/sessions/<id>/ws`.
  The unkeyed page route answers `404`. A keyed request whose key does not
  name the UI session its cookie names is refused with `401`. The exchange
  stays at `/ui/sessions/<id>?ticket=<t>`, and the assets stay at
  `/ui/assets/<name>` and need no cookie. The key decides where the browser
  sends the cookie. A link to another port that does not already contain
  the key does not carry the cookie.
- **The page nonce** is minted at the exchange and delivered only in the
  exchange's `200` body, as the `data-nonce` attribute of `<body>`, never
  in a redirect. The exchange page's script (`/ui/assets/web_view_enter.js`)
  stores it in `sessionStorage` and moves to the keyed page. The keyed
  page's script (`/ui/assets/web_view_page.js`) reads it back, sets it as
  the server component's `csrf-token` attribute, and only then sets the
  component's `route`. Lustre's client runtime puts the token in the
  socket URL's query as `csrf-token`. The upgrade requires it and compares
  its digest with the stored one in constant time
  (`broker/internal/ffi_crypto.constant_time_equal`).

The key is not enough on its own. A person may paste the page's address
into the composer, and then the agent knows the key. A server the agent
runs at `127.0.0.1:<port>/ui/p/<key>/...` then receives the cookie when the
person follows its link. But `sessionStorage` is scoped to scheme, host and
port, so no page on another port can read the nonce. A program holding the
cookie and the key can fetch the keyed page, and that page carries no
nonce. Without the nonce the socket does not open. Getting all three needs a
read of the browser's profile, which this addendum does not defend against,
as the proposal above did not. The session's read scope decides whether the
agent's tools can read the profile.

`sessionStorage` belongs to one browser tab. A reload keeps the nonce, and
a new tab has none. A keyed page opened without a nonce draws a fixed line
saying to run `loom --ui` again, and opens no socket.

**`Referrer-Policy: no-referrer` is now load-bearing.** The exchange URL
carries the ticket and the page URL carries the key. The policy is what
keeps either from reaching another origin in a `Referer` header. The page,
both scripts and the exchange response each carry it, and a test checks
all three.

**The exchange ends the principal's other pages for that session.** The
cookie's path is the key's, so the exchange no longer receives an older
cookie to replace. The exchange therefore ends every UI session with the
same principal and the same session before it creates the new one. Each
`loom --ui` leaves one live UI session for that pair, not one more, and an
older page closes at its next frame.

### Nothing from the session becomes markup

Script on the page's origin could drive an operator's socket. The page's
defence is the policy it already carries (`script-src 'self'`, no inline
script, no `unsafe-eval`) together with these rules for the view:

- Session content (entries, tool output, approval text, names) is drawn
  only as text nodes, which Lustre escapes. The view never uses
  `unsafe_raw_html`.
- No attribute and no event handler is built from session content. No
  `href`, `src`, `action` or `on*` value comes from the session. A path or
  URL in the transcript is drawn as text. List keys come from identities
  the daemon assigns (an escalation's ID and sequence) or from positions,
  never from text.
- The observer's reason for having no composer is a fixed string from the
  component.

`web_view_parity_test` draws a transcript, and `operator_page_test` an
escalation, that hold markup (the escalation also a `javascript:` URL), and
each checks that the HTML carries them only as escaped text.

### The approval card

The card is where the agent would try to trick the person, so it holds to
these rules:

- It draws `approval.presentation` (question, action, authority) from the
  escalation record only, never from transcript text.
- It sits in its own region below the composer, which transcript content
  cannot occupy, and it is styled unlike the transcript. Below, not above:
  the agent chooses when a card appears and how tall it is, and a card
  drawn above the composer would move the composer's controls under a
  click already on its way to them.
- Each button names the tool: "Allow bash once", "Deny bash".
- A newly drawn card never takes focus, and nothing on the page has
  `autofocus`. Enter never approves: the composer attaches no keyboard
  handler, so Enter in its editor is a newline. A draft is sent only by the
  form's own Send, Queue or Steer button, and its submit carries the draft
  and never a decision. The card's buttons are `type="button"` outside any
  form.
- Deny comes first in the card, so it is the first of its controls to take
  focus when the person tabs into the card.
- `Decide` names the escalation's ID and the sequence the card was drawn
  at. A decision is sent only for a pending record with that exact ID and
  sequence. It is encoded with `approval.approve` or `approval.deny`, which
  echo the drawn record's action digest and grants with `expected_seq`, and
  the gateway refuses a mismatch.
- This milestone offers **allow once** and **deny**. **Allow for this
  session** (`approve_for_session`) is left out. A remembered grant
  outlives the page that gave it, so a page opened from a stolen cookie
  could leave authority behind that lasts after the page closes.

### What was considered

- **Operator pages by default, no ceiling.** One fewer flag. Every
  operator's routine read-only page would carry operator rights, so a
  stolen page would be worth the most in the common case. Not taken. The
  ceiling is opt-in per link.
- **Only the page key, no nonce.** The key keeps the cookie off other
  ports until the key leaks, and a paste leaks it. Not taken.
- **A nonce in the page's HTML, or in a `<meta>` tag.** Whoever holds the
  cookie and the key can fetch the page and read it. Not taken. The nonce
  reaches the browser only once, in the exchange's body, which needs the
  single-use ticket.
- **Operator pages only with `--network off`.** It couples the view to the
  sandbox's policy and refuses the common development setup. Not taken.

### Cost

- The Cost entry above on the shared loopback cookie changes. An
  operator's page needs the cookie, the key and the nonce, and only the
  person's browser tab holds all three. A holder of all three gets at most
  operator authority in one session, for up to 8 hours, or until
  revocation, a membership change or a role change.
- Page addresses carry the key, and the nonce lives in one tab. A
  bookmark does not reopen a page, and a new tab needs a new link. Neither
  outlived its UI session before this change either.
- The page socket's operator frame limit (1 MiB) is below the terminal's.
  Image prompts from the page will need it raised, under their own review.
- `ui.link` gains an optional field. A daemon that predates this addendum
  ignores it and mints an observer page, which is the safe reading.

### Verification

- An operator's page submits a prompt that reaches the daemon, and decides
  an approval.
- An observer's command is refused by each layer, tested alone. The
  observer component's type has no command. A mutation frame sent through
  an observer's relay is answered `forbidden` by the gateway.
- Without `--operate`, an operator's page is an observer's page.
- Demoting the principal while an operator's page is open closes the
  socket at the next frame.
- A keyed page route with a valid cookie and another UI session's key is
  refused with `401`. The unkeyed page route is `404`. A socket upgrade
  without the nonce, or with a wrong one, is refused.
- A second exchange for the same principal and session ends the first UI
  session.
- `Referrer-Policy: no-referrer` is on the keyed page, the exchange
  response and the enter script.
- Enter in the composer while an approval card is pending decides nothing
  and sends nothing.
- Mutations, each applied alone and reverted, each fail a named test:
  - the nonce check is skipped;
  - the role ceiling is dropped (the page takes the membership role);
  - the ceiling lets `Owner` through;
  - a key handler on the composer's editor decides the pending card on
    Enter;
  - the socket starts the operator component for an observer;
  - the gateway's observer refusal is removed.

## Addendum: opening the browser (2026-09-26)

The Open item "Opening the browser" is settled. `loom --ui --session <id>
--open` prints the link exactly as before and then hands it to the
platform's opener: `open` on macOS, `xdg-open` on Linux. Nothing on the
wire changes. The daemon never learns whether a link was opened, and
`ui.link`, the ticket and the exchange are untouched.

**The link is always printed, and printed first.** A headless machine or
an SSH session has no browser to open, and there the printed line is the
only way in. Printing it before the opener runs also means an opener that
hangs or fails leaves the person holding a working link.

**A failed opener is a note, not a failure.** A missing opener, one that
cannot be started, and one that exits non-zero each print one line on
standard error, and `loom` still exits 0, because the link it printed
works. The note is built only from the opener's name, its exit status or
the platform name. Text the opener or the operating system produced is
dropped, since an opener may echo its argument and the note must never
carry the ticket. The link is the first line of standard output; with
`--open` the opener's own output is forwarded after it, so a script takes
the first line.

**The platform comes from the launcher.** Every launcher Loom builds
(`bin/loom`, the shipment and the release) exports `LOOM_BUILD_PLATFORM`
as `macos-<arch>` or `linux-<arch>`, and `loom version` and `loom update`
already trust it. A `loom` run without a launcher has no such variable, so
`--open` prints a note rather than guessing. Probing `PATH` for whichever
opener exists was rejected: some Linux distributions ship `/bin/open` as
`openvt`.

**No new FFI.** The opener runs through `ffi_terminal.run_forwarding`, the
same `open_port` passthrough `loom ext` and `loom update` use, with the
link as its single argument and no shell between. A one-task weft run
bounds the wait at five seconds. `xdg-open` outside a known desktop runs
the browser in the foreground and exits only when the browser does, so an
opener still running at the deadline counts as a browser that started;
the port closes, and the opener keeps running.

**Where the ticket goes.** Standard output, as before, and the opener's
argument vector. It is written to no log and no file. The argument vector
is readable by other local users through `ps` for as long as the opener
runs, and for as long as the browser runs when `xdg-open` starts the
browser itself. A local user who races the browser to the exchange gets the page the
ticket was minted for, observer access to one session or, with
`--operate`, an operator's page, and the person's own browser then lands
on a `401` because the ticket is spent.
A same-user process could already read the owner credential, so the
exposure is to other accounts on a shared machine. Printing without
`--open` avoids it entirely.

The seam is `tui/view_link`: `opener_for` chooses the command,
`platform_opener` builds the opener from injected find and launch
functions, and `deliver` takes the opener and the printer, so the tests
drive every failure without a browser.

## Addendum: remote access (2026-09-26)

The Open item "Remote access" is taken up by
[protocol-change/052](052-web-view-remote-origin.md), proposed and not yet
implemented. It keeps this proposal's loopback admission unchanged and
adds a second page origin: a TLS-terminating proxy on the daemon's host,
at a host name listed with `loomd --ui-origin`, with a `__Host-` `Secure`
cookie, an exact `https` `Origin` rule and a `wss:` socket policy. A
teammate mints their own ticket with `loom --ui --addr wss://…` and their
member credential.

## Addendum: the pinned composer and the approval card (2026-09-27)

The operator addendum placed the approval card in its own region below the
composer. The first live drive of an operator's page (issue #569) found
two problems with that layout. The composer sat in the document's flow
under the transcript, so it moved down each time a row landed and each
time its editor grew, and a click aimed at Send or Steer landed on
whatever had moved under the pointer. And the card, below the composer at
the very end of the page, was off screen whenever the operator had
scrolled up to read.

**The composer is pinned.** The composer is drawn in a dock, a footer
the stylesheet pins to the bottom edge of the viewport with `position:
sticky`. It no longer moves when the transcript does.

**The card sits directly above the composer, inside the dock.** A
pending card is therefore on screen wherever the operator has scrolled.
The reason this addendum's original rule gave for "below, not above" was
that a card drawn above the composer would move the composer's controls
under a click already on its way to them. That held for a composer in the
flow, which a card above it pushed down. It does not hold for a composer
pinned by its bottom edge: a card appearing grows the dock upward, and
the composer's controls stay where they were. The region's height is
capped at 35% of the viewport and scrolls on its own, so a long action
preview cannot push the composer off the screen.

Every other rule for the card is unchanged: it is drawn from the
escalation record alone, in a region transcript content cannot occupy and
in a style no transcript line uses; Deny comes first and each button
names the tool; nothing takes focus; the card's buttons are
`type="button"` outside the composer's form; and a decision names the
drawn identity and sequence. The client component that follows the tail
(`<loom-follow>`) wraps only the lane, so it neither reads nor scrolls
anything in the dock.

**What was considered.**

- **Keep the card below a pinned composer, inside the dock.** The card
  would still be on screen, and a card appearing below the composer would
  push the composer up, which is the movement the original rule refused.
  Not taken.
- **Draw the card beside the call that holds the claim, in the
  transcript.** The direction in `docs/design-notes/web-ui.md` already
  places a buttonless `waits for approval` marker there. A card with
  buttons inline in the transcript would move every row after it when it
  appears and leaves, and would sit in the region transcript content
  occupies. Not taken.

**The card's buttons are armed after a delay.** For 600 ms after a card is
inserted, its action row refuses clicks and its buttons are drawn dimmed.
The dock covers the bottom of the transcript by the height of any pending
cards, so a card that appears while the pointer is travelling toward a
transcript row just above the dock could otherwise take that click on
Allow. Browsers delay their own permission prompts in the same way, for
the same reason. The delay is a CSS animation on the action row, keyed
off its `arming` class: the keyframes hold `pointer-events: none`, and
when the animation ends the row goes back to its own style. It needs no
script, no client component near the card, and no server timer. It runs
once per card, because cards are keyed by the record's sequence and a
later patch updates the same node rather than inserting a new one. A page
that reconnects draws every card again and arms each one again, which is
the right reading for a card the person has not seen since. With
`prefers-reduced-motion` the dimming is not drawn, and the delay still
applies. The delay does not affect the keyboard: nothing on the page takes
focus when a card appears, so a key cannot reach a new card's buttons
without the person first moving focus to them.

**Ruling (owner, 2026-09-27).** The cards stay above the composer in the
dock, with the arming delay above.

**Cost.** The dock covers the bottom of the transcript by the height of
any pending cards, and a card's buttons do nothing for their first 600 ms,
so a person who reads fast and clicks at once has to click again. The
page tests pin the placement and the arming class (`operator_page_test`).

## Addendum: history paging on an observer's page (2026-09-27)

The web view now holds a bounded number of transcript rows and loads older
ones on request (issue #569, PR #590). The request is the lane's `history`
read, the read the terminal pages with: a "Load older" button above the
lane's oldest row sends it for the hundred sequences below. Under the
operator addendum, an observer's page carries no event handler at all and
its socket drops every browser frame, so an observer could follow the
session but never read further back than the page held.

**Ruling (owner, 2026-09-27).** An observer's page may carry exactly one
event handler: the fixed "Load older" click. The page socket admits only
that event from an observer and nothing else.

**Why.** Reading history is observation. The gateway already admits a
`history` read from an observer's binding (`gateway.read_only` lists
`History`), and the lane sends it on any attachment. What the observer's
page lacked was a way for the browser to ask, not the right to the read.

**What it is, exactly.**

- The observer's message type gains one constructor,
  `component.OlderRequested`. Its only effect is `component.older`, which
  asks `history_view` for older records and sends the `history` read on
  the page's own lane. It holds no command, and no message can widen the
  type while the page runs, so the component's type still cannot produce
  a mutation.
- The observer's view attaches one handler: `click` on the lane's "Load
  older" button, drawn only while older rows exist. Its path is the
  constant `component.older_path`, and `page_events_test` pins that the
  observer's rendered view registers that one handler and no other.
- The page socket's filter for an observer (`ui_socket.observer_accepts`)
  admits a Lustre `EventFired` frame only when its kind is 1, its name is
  `click` and its path is `component.older_path`. Every other frame is
  dropped before the runtime sees it: any other event name, a click at
  any other path, a batch, a frame of another kind, and a malformed frame.
  The inbound frame limit stays at 64 KiB.
- The gateway's refusal of an observer's mutation is unchanged and still
  stands on its own, as does the lane's (`session_channel.can_mutate`).

**What was considered.**

- **Keep observers from paging.** The page would stay bounded, and an
  observer would lose history they are entitled to read. Not taken.
- **Page automatically when the observer scrolls to the top.** The browser
  would still have to tell the server, which is the same one event with a
  second trigger that is harder to reason about. Not taken.

**Cost.** One read-only browser event is admitted from observers. A holder
of an observer's page (its cookie, key and nonce) can make the daemon read
and send up to a hundred sequences of history per press, one read at a
time on the page's lane, which is what the same person's terminal may
already ask for. A press also raises that page's row limit from 150 to
300 for the rest of the page's life (`component.held_rows`), so an
observer's page can hold up to twice the rows, and about a fifth more
memory than the plain-row page Markdown was measured against (#590). The
socket also parses every frame an observer sends, up to the 64 KiB limit,
where it used to drop each one unread. The observer's page is no longer
free of handlers, so
"an observer's view attaches no handler" in the operator addendum now
reads "an observer's view attaches only the Load older click".

**Verification.** `ui_socket_test` admits the click at `older_path` and
drops a submit, a click elsewhere, a forged event name at the button's
path, a batch and malformed frames. `page_events_test` pins the observer's
one handler. `paging_test` shows an observer's click reaching
`OlderRequested`, an observer's press writing one `history` frame and no
command, and a forged submit on the button finding no handler.

## Addendum: the operator page runs session commands (2026-09-29)

**Status**: ACCEPTED, IMPLEMENTED in #618 · **Raised by**: issue #569, the
shared step's extraction (`docs/design-notes/step-extraction.md`, S5)

**Ruling (owner, 2026-09-29).** The operator page runs every session
command a draft names, except adding a directory. It parses the draft with
`command.parse_with_skills` and routes a `command.Session` through
`commands.act`, as the terminal does. A `command.Surface` command is
refused on the page with a notice and sends nothing.

This supersedes the statement in "Addendum: operators act from the page"
that the page "has two commands", `Submit` and `Decide`. Those are still
the page's two events, and the socket's accepted events are unchanged. What
changed is what `Submit`'s text may be. Before, the text always became a
prompt or a steer. Now it may name any session command: `/compact`,
`/goal ...`, `/model <name>`, `/effort`, `/fork`, `/abort`, `/unschedule`,
`/approve`, `/deny` and the rest of `command.Session`. The earlier addendum's
text is left as written.

### What a page is worth now

The operator addendum priced a stolen operator page as the power to send
prompts that run tools and to approve escalations. It is now worth what a
terminal attachment with the Operator role is worth, less adding a
directory. A holder of all three of the cookie, the page key and the nonce
can also:

- switch the model or the reasoning effort, which changes what the session
  spends;
- fork a strand, and abort a running one;
- set, check, pause, resume and clear the session's goal;
- compact a strand, and retire a schedule.

Adding a directory (`/add-dir`, `/add-write-dir`, `/add-dir --write`) is
the one command that widens the session's filesystem scope. The page does
not run it, so a stolen page cannot widen scope.

What still bounds a page, checked against the branch:

- **Pages are capped at Operator.** `ui_relay.capped`
  (`packages/client/src/client/daemon/ui_relay.gleam:98`) returns Operator
  at most and never Owner, and the relay attaches with that role.
- **The gateway refuses an observer's mutations.** `run_command` answers
  `forbidden` to a mutation from an observer binding
  (`packages/client/src/client/gateway.gleam:4201`), classifying commands
  with `read_only` (`gateway.gleam:2723`). That is its only role gate on
  mutations. It does not distinguish an operator's page from an operator's
  terminal.
- **The one Owner-only gate is worktree observation**
  (`worktree_owner`, `gateway.gleam:3778`, reached through
  `observation_allowed`, `gateway.gleam:707`). The page never requests it:
  the read is requested only when a `WorktreeShown` surface fact arrives
  (`lane_fold.gleam:1163`, sent at `surfaces.gleam:235`), which the
  terminal's `/diff` raises. `/diff` is a `command.Surface` command and the
  page refuses it.
- **An observer's page carries no command.** `component.Msg` has no command
  constructor, and `submit` and `decide` are reachable only from
  `operator_page`. `ui_socket.start_page`
  (`packages/client/src/client/daemon/ui_socket.gleam:380`) starts that
  component only for `Operator` or `Owner` authority (`role_of`, line 293).
  The observer socket admits one event, the Load older click
  (`observer_accepts`, line 102).
- **Session content still renders only as text nodes.** The rules in
  "Nothing from the session becomes markup" are unchanged, and so is the
  content security policy.

None of these bounds is new. The change is that the Operator role, which
the earlier addendum treated as prompts and approvals, is now exercised in
full. The same-origin, cookie, page-key and nonce defences are what stand
between the agent and the page, and this addendum leaves them as they were.

### What the page refuses

`component.page_command`
(`packages/web_view/src/web_view/component.gleam:1103`) is the one place
that names what the page does not run:

- **A `command.Surface` command** (`/help`, `/models`, `/sessions`, `/diff`,
  `/details` and the rest). The page has no such surface, and sending the
  words to the model as a prompt would run them as an instruction.
- **`command.AddDirectory`.** `/add-dir` and `/add-write-dir` name a path on
  the daemon's host. A browser reader, who may be on another machine
  ([protocol-change/052](052-web-view-remote-origin.md)), can neither see
  nor pick one, and these are the only commands that widen the session's
  filesystem scope. The notice tells the person to add directories from a
  terminal on the daemon's host.

Each refusal sends no frame and keeps the draft. The empty-draft and
`prompt_limit` checks in `component.submit` are as they were.

### What differs from the terminal

- **Skill slash commands are refused as unknown.** The page loads no
  skills catalogue, so `command.parse_with_skills` finds no skill and the
  shared step answers `unknown command`. The page used to send such a draft
  to the daemon as a prompt. Reading the catalogue is a follow-up.
- **A returned prompt is dropped.** When the daemon hands back a held
  prompt (the custody return of
  [protocol-change/038](038-held-input-custody-return.md)), the terminal
  restores it to its editor. The page has no editor to restore it to, and
  `step.forget_surfaces` drops it, as the owner ruled on question 12 of the
  step extraction. The text is not shown anywhere on the page, and the page
  draws no notice for it. The prompt's last copy is lost.

### What was considered

- **Keep the page to a prompt and a decision.** It keeps the price of a
  stolen page where the operator addendum set it. The page would then need
  its own parse and its own list of commands, and would drift from the
  terminal's. Not taken.
- **Run `/add-dir` on the page.** It is the command most worth a stolen
  page, and the path it names is a path the browser cannot check. Not taken.

### Cost

- A stolen operator page can change the session's model and effort, fork,
  abort, and mutate the goal. The bounds above hold it to one session and
  to the Operator role, for at most the UI session's lifetime.
- The page's gateway role check treats an operator's page and an operator's
  terminal alike. A rule that only the terminal may run a command needs a
  check in the gateway, which this addendum does not add.

### Verification

`operator_page_test` shows `/compact` sending a `compact` command and not a
prompt, an unknown command refused and sending nothing, a terminal surface
command (`/models`, `/sessions`, `/details`) refused with a notice, and
`/add-dir`, `/add-write-dir` and `/add-dir --write` refused with a notice and
no frame.

## Addendum: the composer's element (2026-09-28)

**Status**: PROPOSED, IMPLEMENTED with issue #569, part 2 · **Raised by**:
issue #569 (slash-command completion, a send key, the notice, a returned
prompt)

The composer's editor is an uncontrolled `textarea`. The browser owns the
text as the operator types, and the server never sees it until the form is
submitted, so four things that react to the draft as it changes could not
be done on the server. This addendum puts them in a client component,
`<loom-composer>` (`packages/web_client/src/web_client/composer.gleam`),
which wraps the server's textarea and takes it as its default slot. It adds
no handler to the server's tree, no event to the socket's accepted list,
and no change to the content security policy.

### What it does

- **Slash-command completion.** A draft that is one word starting with
  `/` lists the session commands the page can run, narrowed as the draft
  grows, with the names and hints the terminal's completer gives
  (`session_view/command.suggestions`). A command whose argument has a
  closed vocabulary (`/effort`, `/goal`) keeps listing its words past the
  space. The arrow keys move, Tab and Enter take the highlighted row, and
  Escape closes the list. A row is offered only when the page would run the
  command it names: `web_view/completion` builds the table from the
  terminal's suggestions and drops a row exactly when
  `component.page_command` refuses the command, so a terminal surface
  (`/help`, `/models`, `/sessions`) and adding a directory are not offered.
- **A send key.** Command or Control with Enter submits the composer's
  form as its first submit button does (Send, or Queue while the strand is
  busy). Enter alone is still a newline. The key calls `requestSubmit`, so
  the server receives the `submit` event the form already registers.
- **The notice.** The page draws outcomes only (see below), not the shared
  record's notice.
- **A returned prompt.** A held prompt the daemon hands back
  ([protocol-change/038](038-held-input-custody-return.md)) is put back in
  the editor. This supersedes the statement in "Addendum: the operator page
  runs session commands" that the page drops it.

### What crosses from the server to the element

The element's inputs are two attributes and a slot, and none is session
text as an attribute.

- `commands`: the completion table as JSON. Every row is a command name
  and a hint written in `session_view`, never text the session produced.
- `returned`: how many prompts the daemon has handed back, a number.
- Children in the slot named `returned`: each returned prompt as a text
  node in a `span`, with its number in `data-n`. The element's shadow root
  has no such slot, so the browser draws none of them; the element reads
  their text. The prompt is what the operator typed and it is drawn only as
  text, as every other piece of session content is.

Nothing goes from the element to the server except the form's submit, which
the operator's own key or button raises.

### What the element may do, and what changes in the rules

The earlier addenda kept client components from handling keys or taking
focus. That rule was written for the approval card, where a stray key must
never become an answer, and this addendum narrows it to say so:

- The element listens for `input` and `keydown` on its own editor only,
  through its slot, and never inside an approval card. The approval region is
  outside it, in the dock. No key the element handles decides an approval:
  the send key submits the composer's form, which sends a prompt or a
  command and decides nothing.
- It calls `focus` on the editor once, when the operator chooses a row from
  the list (by key or click), so the caret is in the editor after the
  completed text. It never focuses on its own, and nothing has `autofocus`.
- It writes the editor's value in two cases only: a row the operator chose,
  and a returned prompt. It reads the editor's text for two purposes: to
  narrow the list, for which it keeps the first 200 characters, and to see
  whether a returned prompt follows text the operator typed. It sends none
  of it anywhere.
- The `commands` attribute holds the static table of command names, not a
  daemon identity or a number. That is the one attribute a client component
  now reads that is not one of those, and the table is written in
  `session_view`, not produced by the session.

### The notice is an outcome

The shared record's notice is replaced by any event: a stream ("streaming
text"), a read the lane sends by itself ("advisor_pending sent" on every
page load), a capture. The page drew it, so it said whatever the session had
said last. It now draws only what the operator's commands and the daemon's
answers to them said: its own refusal, the daemon's reply to the last
command (`Shared.answer`, which only a reply writes), or what the shared step
worded when the page ran the command. `Shared.answer` is new in
`session_view` and additive: the terminal reads the notice as it did.

### A returned prompt

The editor is uncontrolled, so only the browser knows whether the operator
has typed since the prompt was sent. The element puts the returned text in
an empty editor, and below what the operator has typed, after a blank line,
in an occupied one, which is what the terminal does
(`inbound.restore_returned_drafts`): both texts are the operator's, and
neither may be lost. The notice says how many prompts came back and for
which strand. The page composes only for `main`, so a prompt held for
another strand or session is named in the notice and not restored: the
page has no editor for it.

The step no longer discards it. `step.forget_surfaces` leaves
`Shared.returned_drafts` alone, and the web component takes the prompts at
the end of every message (`docs/design-notes/step-extraction.md`, question
12, amended).

### What was considered

- **Put the returned text in the server-rendered editor.** The server
  would replace the textarea with one holding the text. The server cannot
  tell whether the operator has typed in the editor since, so this would
  replace their draft. Not taken.
- **Send the draft to the server as it changes.** It would let the server
  own completion, at the cost of an `input` handler that fires per
  keystroke, a new event on the socket's accepted list, and the draft
  leaving the browser before the operator sent it. Not taken.
- **A second list of commands in the client.** Two lists drift. The table is
  built from the terminal's own.
- **Enter submits, or the list's Enter submits a complete command.** The
  terminal submits a complete command chosen with Enter. On the page Enter
  is a newline and choosing a row only fills the editor, so a keystroke
  never sends on its own; the operator presses Command or Control with Enter.

### Cost

- The page carries one more client element and one more `.mjs` file of
  browser calls (`internal/composer.mjs`, four functions), beside the two
  that were there.
- The `commands` attribute is about 3 KB, sent with the composer and
  unchanged between renders.
- A returned prompt is held on the page, all of them (none may be lost, and the list is bounded
  by the daemon's held queue), until the
  page ends.

### Verification

`completion_test` shows every row is one the terminal offers with the same
name and hint, a command the page refuses is not offered, and the
argument rows are. `returned_test` shows a returned prompt kept and
numbered, the notice naming the strand and count, the editor not replaced,
the view carrying the count and the text as escaped text, and a prompt for
another strand named and not restored. `operator_page_test` shows a page
that has only loaded saying nothing, background events not speaking over a
command's outcome, and only a command's refusal drawn.
`page_events_test` shows the operator's page registering only clicks and
submits. `session_view/step_test` shows a reply kept as the answer and a
returned prompt kept through `forget_surfaces`.

The element's keys, list and restore run in the browser and are not in
`make check`. They were exercised in a browser against the built bundle:
the list narrowing and moving, Tab and Enter taking a row, Command and
Control with Enter submitting the form with `draft` and `delivery` and no
newline, and a returned prompt filling an empty editor, following typed text,
being taken once when two returns land within a frame, and not returning
when an editor is drawn afresh.
