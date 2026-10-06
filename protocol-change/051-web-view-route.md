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

**Superseded (2026-09-29, see "Addendum: images in the transcript and the
composer"): an operator's page socket now takes 12 MiB, which holds a draft and
8 MiB of images.** The paragraph above is the rule as first written, kept so
the reason for it stays findable.

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

**Superseded (2026-09-29, see "Addendum: several pages per principal and
session"): the exchange no longer ends the principal's other pages.** The
paragraph below is the rule as first written, kept so the reason for it
stays findable.

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
  never from text. (The one `src` the view builds, for a transcript image,
  is made of the page's own session, the engine's name for a row and a
  number; see "Addendum: images in the transcript and the composer".)
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
  session. (Superseded: it leaves the first open, and the fifth ends the
  oldest; see "Addendum: several pages per principal and session".)
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

## Addendum: the page's frame is pinned and only the transcript scrolls (2026-09-29)

**Status**: ACCEPTED · **Raised by**: issue #569, phase B (owner,
2026-09-28: new rows landed below the viewport)

The pinned-composer addendum above pinned the dock with `position: sticky`
inside a page that scrolled as a whole. This addendum replaces that with a
fixed frame on both pages: the page is one viewport tall and never
scrolls; the heading and the agent strip are at its top; the dock (the
operator's approvals and composer) or the observer's bar is at its bottom;
and the transcript, which takes the height between them, is a scroll
container of its own. The dock is no longer sticky. It is the last item of
the page's column, so a card appearing or the editor growing shrinks the
transcript rather than covering its last row. Everything the earlier
addendum says about the card (above the composer, capped at 35% of the
viewport, the arming delay) is unchanged.

**The client component is the scroller.** `<loom-follow>`, which wraps the
lane, becomes the transcript's scroll container. It scrolls itself, so it
takes no new event and adds nothing to the socket's accepted list: scrolling
is client-side only, as it was. Its shadow root gains one button, "Jump to
latest", drawn only while the reader has scrolled up more than 40 pixels
from the bottom. The button's label is fixed in the component; it takes no
session text, no attribute and no key handling. The approval cards and the
composer are still outside it, in the dock. The content security policy,
the served documents and the session's text nodes are unchanged.

**Why following failed before.** `<loom-follow>` decided between following
and reading from the distance to the bottom at each scroll event. Its own
scroll to the bottom is reported on the next frame, and rows that landed in
between made that distance more than 40 pixels, which it read as the reader
scrolling up. It then stopped following for the rest of the page's life. A
burst of rows, which a busy session produces constantly, was enough. The
component now reads which way a scroll moved as well: only a move up that
ends away from the bottom is the reader leaving the tail.

**What was considered.**

- **Keep the page as the scroller and only fix the decision.** That fixes
  the loss of following but leaves the dock overlaying the last rows and the
  header scrolling away. Not taken.
- **Draw "Jump to latest" from the server.** It would need the reader's
  scroll position on the server, a render per scroll, or a new event on the
  socket's accepted list. Not taken.

**Cost.** Scroll anchoring is turned off for the transcript, so the
component keeps the reader's place itself in every browser, including when
older rows load above them. The transcript is shorter on a short window,
by the height of the dock and the strip.

### Verification

`operator_page_test` and `component_test` pin the order of the page's
children (heading, strip, transcript, dock or bar). The scroll behaviour is
in the browser, where the tests cannot reach it, and is checked by hand.

## Addendum: one DOM binding, and the follower hears the reader (2026-09-29)

The client components' logic moved from three JavaScript files
(`follow.mjs`, `composer.mjs`, `clock.mjs`) into Gleam over one binding,
`internal/dom.mjs`, whose every export is a single DOM call or property read
(issue #569, part 2). Nothing the page sends, accepts or is allowed changes:
no new event on the socket, no HTML written, no key acted on outside the
composer's editor, and the policy is unchanged. `scripts/web_client_js_check.sh`
now fails the build if that file is not the only JavaScript in the package or
names `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `eval`, `new Function`,
`document.write`, `srcdoc`, `DOMParser`, `createContextualFragment` or a
dynamic `import(`. That is a textual check, not a proof: the guarantee is that
the file is a short list of one-call exports a reviewer reads.

One behaviour is new and belongs here. `<loom-follow>` listens, passively, for
`wheel`, `touchstart`, `touchmove`, `pointerdown` and `keydown` on itself, and notes only
when each happened. It reads nothing from the events and cancels none. A scroll
up that ends away from the bottom now leaves the tail only when the reader made
it: one of those events was heard within half a second, or the transcript is
the size it was at the last scroll. A scroll the browser makes to fit a box that
grew or content that shrank, heard after rows landed, was being taken for the
reader leaving, which stopped the follow in the middle of a burst of rows. The
`keydown` listener is the rule's one touch: it is passive, reads nothing from
the event (not the key, not its modifiers), never cancels it and sends nothing
to the server, and it hears only keys pressed with focus inside the transcript,
which holds no approval card. Only the composer acts on keys; the follower
notes that one was pressed, so a keyboard scroll counts as the reader's. The
owner approved it on 2026-09-29. The cost that remains: while content is
growing, find-in-page, a key pressed with focus outside the transcript and a
Firefox scrollbar drag (no `pointerdown` there) see a changed size, so they read
as the layout's and cannot leave the tail until the growth stops. Wheel,
trackpad, touch and keys in the transcript are unaffected.

**Verification.** `packages/web_client/test` runs the decision as pure
functions and as sequences of the element's messages. The listeners, the scroll
events and the DOM calls run only in a browser, which `make check` does not
have.

## Addendum: expanding a row is client-side (2026-09-29)

The page lets the reader expand a row, as the terminal's `Ctrl+g` does. It
adds no event to the socket's accepted list and no read: the page already
holds the records, so the server draws the compact and the full form of a row
that has more to show, as the children of a new client element,
`<loom-expand>`, and the element shows one of them. Both forms are session
text drawn as text nodes (a program is a `<pre><code>`), the element has no
attribute, handles no key, and its button's words are fixed. Each expanded row
is cut to 300 lines or 8,000 characters. The content security policy is
unchanged. Considered and not taken: asking the server for the full row on
click, which would be a new page event and a round trip for text the page
holds.

The heading's status now says "connected" where it said "following". It is the
connection's state, and the word was read as the scroll state, which only
`<loom-follow>` knows.

## Addendum: a page with no session says why (2026-09-29)

A page can lose its session in several ways, and until now none of them told
the person anything (issue #569, part 2). Redeeming a new link ended the
principal's other page for the session (the ticket section above; the
addendum on several pages, below, replaces that rule), but the
ended page kept a stale transcript under a small header word, and reloading it
answered "no page session under this key". A page whose socket the daemon
refused stayed empty, because Lustre's client runtime reconnects after any
close code but 1000 and a refused handshake shows the browser only that it
failed. This addendum decides what the page says, in what words, and which
close code ends the socket. It adds no event to the socket's accepted lists,
no route, no script logic, and does not touch the content security policy.

**What was found first.** Most refusals were never a 1000 close. A refusal in
the router (a missing or expired page session, a revoked credential, a
session that is not resident, no free permit) answers the WebSocket handshake
with an HTTP status. The browser reports that as a failed connection with
close code 1006, which Lustre's runtime retries after 500 ms, doubling to at
most ten seconds, for as long as the tab is open. Those tabs were empty and
silent, not final. The 1000 closes came from three places after the upgrade:
the permit's transfer timing out, the component failing to start, and a
page's end from the gateway. The relay's own attach refusal left the socket
open with a header word.

### The endings

One closed type, `web_view/ending.Ending`, names why a page has no session.
Everything the page says about it is a fixed string chosen by the variant, and
a reason string that names no variant is drawn as `ConnectionFailed`, so no
text from a peer, a session or an error message reaches a browser.

| Ending | Cause | Says | Socket close |
|---|---|---|---|
| `PageEnded` | The page's UI session is gone: its eight hours ran out, the daemon restarted, or it was the oldest of the principal's four pages for the session and a newer link took its place. The daemon keeps no record of which. | "This page has ended." A page lasts eight hours, and the daemon forgets every page when it restarts. You can also have 4 pages open for a session at once; opening another ends the oldest. Run `loom ui --session <id>` for a fresh link. | 1000 |
| `AccessRevoked` | The credential behind the page, or the membership under it, was revoked, or the capped role changed. The socket's own check answers this reason when it refuses. | "Your access to this session was revoked or changed." Ask the owner to restore it, then run `loom ui --session <id>`. | 1000 |
| `SessionStopped` | The gateway exited (the session stopped, or the daemon shut it down), or closed the attachment while the page's check still passes with the authority it attached with (its snapshot reader failed and the incarnation is stopping). | "The session stopped." Open it again, then reload this page; the page's own link still works, so a fresh one is not needed. | 1000 |
| `NotOpen` | The gateway refused the relay's attach. | "The session is not open." The daemon may still be opening it: reload, and if it stays closed run `loom ui --session <id>`. | 4000 |
| `DaemonNotReady` | The daemon was starting, stopping or too slow to answer. | "The daemon was not ready." Reload in a moment, and if it keeps failing run `loom ui --session <id>`. | 4000 |
| `LinkExpired` | The ticket was already redeemed, or its 60 seconds passed. | "This link has expired or was already used." Run `loom ui --session <id>` for a fresh one. | not a socket |
| `ConnectionFailed` | Any other end, including a lane that failed. | "The connection to the session failed." Reload, and if it fails again run `loom ui --session <id>`. | 1000 |

`SessionStopped` is the one ending whose page is still good: the UI session
lasts eight hours and serving the page does not need the session resident, so
a reload reconnects once the session is open again. `PageEnded` and
`LinkExpired` do not tell the person to reload: a page whose
key is gone has nothing to reload into. The session identity in the advice is
drawn only when it parses as a canonical identity; the address of a refused
page is otherwise whatever a link said, and the notice would repeat it as a
command to run.

### Close codes

The client runtime is the only reader of the code, and it reads one bit of it.

- **1000 is final.** The runtime does not reconnect. The page uses it after the
  component has drawn a notice the person must act on, so the notice stays and
  the daemon is not asked again every ten seconds.
- **4000 is retried.** Mist sends 4000 when a socket handler stops abnormally
  (`mist.stop_abnormal`), and the runtime reconnects after its backoff. The page
  uses it for endings the daemon may clear by itself, and for the two failures
  in `ui_socket.admit` that are the daemon's alone: the permit transfer
  running past its second, and the component's start running past Lustre's
  one-second budget. A tab that hit one of those used to close with 1000 and
  stay empty for good.
- **1006, a failed handshake, is retried and cannot be changed.** The router's
  refusals stay HTTP statuses, because a WebSocket that is not upgraded cannot
  carry a frame. The runtime keeps retrying them, at most every ten seconds.
  For a transient refusal that is what is wanted. For a permanent one it costs
  the daemon one refused request per ten seconds per open tab, refused at the
  cookie lookup or the resident check, and the person sees the page's waiting
  paragraph (below). Stopping the loop would take either an upgraded socket
  that closes with 1000, or script in the page that removes the component's
  `route`. Neither is taken here.

A relay that cannot start reports `DaemonNotReady`, so that socket closes
with a retry as well. The socket picks the code from the ending the relay
reports: `ending.close`
maps `NotOpen` and `DaemonNotReady` to a retry and every other ending to a
final close. `ui_socket` still waits a quarter second before closing so the
component's patch for the notice is sent first.

### What the page shows

- **A live page that ends** draws a notice inside its heading, after the
  status, as a row of its own: the headline, and the advice. The status word
  reads "disconnected", with no reason after it. The notice is inside the
  heading so that no region after it changes its path; `component.older_path`
  and the composer's form keep the addresses they had. The last cut of the
  transcript stays, as before, under the notice. `web_view/view/ended` draws
  it from the ending, as text nodes.
- **A page that is reloaded after it ended** is answered with a document for
  the ending in place of the bare status text: `page.refusal`, the stylesheet
  and no script, under the same headers and the same status code as before
  (401 for a missing page session or a revoked credential, 403 for another
  session or a non-member, 503 for a daemon that is not ready). A ticket
  exchange for a link that was used or expired is answered the same way with
  `LinkExpired`.
- **A page that never connects** is not blank. The shell puts one fixed
  paragraph inside the `<lustre-server-component>` element as light-DOM
  content. The client runtime attaches the component's shadow root when the
  first tree arrives, and a shadow root with no slot hides its host's light
  content, so the paragraph shows exactly while the page has no session:
  before the socket connects, while the daemon refuses it, and when the tab
  has no nonce. It says that the page is not connected, lists the causes
  a person can tell apart by trying (the daemon may still be starting, the
  session may not be open, the page may have ended, the tab may have lost
  its key), and
  gives the two remedies: reload, or run `loom ui --session <id>` for a
  fresh link. The session page's script no longer writes its own note for a
  tab with no nonce; the paragraph covers it.

### What was considered

- **A `web_client` element that watches `lustre:close` and draws the notice.**
  It would cover a page that drops after it mounted, and could give up after a
  bounded number of retries. It needs new `dom.mjs` exports (an event listener
  on another element, attribute writes), a rule module and a test target, and
  it still cannot tell an ended page from a daemon restarting, because the close
  event carries no code and the handshake's status is hidden. Not taken; see the
  cost below.
- **A status endpoint the page's script polls after a close.** A new route and
  new script logic to recover what the socket already knew. Not taken.
- **Upgrade every refused socket and close it with a code.** Only the refusals
  after the page's cookie, key and nonce check could be upgraded without
  opening the socket to any peer that passes the origin check, and the notice
  would still have to be drawn by a component started for the purpose. Not
  taken.
- **Tell a replaced page from an expired one.** It needs a record of ended UI
  sessions, which is state the daemon otherwise never keeps. The advice is true
  of both, so `PageEnded` covers them.
- **Ending as a typed field of `connection_event.Closed`.** The event is the
  session engine's and the terminal uses it; the string it carries stays, and
  `ending.reason` and `ending.from_reason` are the two halves of the hop,
  held to each other by a test.

### Cost

- A tab that lost its socket after mounting, by a daemon restart or a network
  break, still shows its stale transcript with the header's last word until
  the runtime reconnects, and after a restart it is refused on every retry.
  Nothing on the page says so. Only a page that the gateway ended, or whose
  attach the relay was refused, gets a notice. A client element could close
  this gap; it is the follow-up the decision above left out.
- A permanent handshake refusal is retried every ten seconds for as long as the
  tab is open, behind the waiting paragraph.
- A 4000 close exits the socket process abnormally, which the mist supervisor
  logs as a child termination. It is rare (a session that was opening, or a
  root that was slow), and the retry is the point.
- The relay asks the attachment's check a second time when the gateway closes
  it, to name the cause. The check is the page's own authorization and changes
  nothing.

### Verification

`ending_test` holds the three tables to each other: every ending round-trips
through its reason string, no two share a reason or a headline, only
`NotOpen` and `DaemonNotReady` are retried, and every advice names the
command with the session. `component_test` and `operator_page_test` draw
each ending on both pages, draw a reason that names none as
`ConnectionFailed` with none of its words, and keep the heading's children in
place. `page_test` pins the waiting paragraph inside the component and the
refusal document's escaping. `ui_relay_test` shows a displaced or expired UI
session ending the page as `PageEnded`, a revoked credential as
`AccessRevoked`, and a refused attach naming `NotOpen` to both the component
and the socket. `ui_route_test` reloads an ended page and a used link and
reads their notices, checks that an address that is not a session identity is
never repeated, and drives a real WebSocket to a page whose gateway is not
running: the notice is in the frames the browser gets, and the close code is
4000. No browser is in the loop. That the client runtime hides the light-DOM
paragraph when it mounts, and retries after 4000 and not after 1000, was read
in its source (`docs/lustre.md`) and is left to the hand check on a live
daemon.

## Addendum: several pages per principal and session (2026-09-29)

The owner ruled on issue #569 that a principal may hold more than one page on
a session: an observer's tab beside an operator's, or two devices. The ticket
section above did the opposite, and this addendum replaces that rule. It adds
no route, no event and no field to the wire, and does not touch the content
security policy.

### The problem

A page's cookie is scoped to its key's path, so the exchange never receives an
older cookie to say which page a new link replaces. The first answer was to
end every UI session of the same principal and session at each redemption,
which kept one live page per pair and needed no other bookkeeping. It made
these ordinary uses fail without a word: running `loom ui --operate` while an
observer tab was open ended the observer tab, and a second device ended the
first. The ended page said only that a new link had ended it.

### What was decided

- **A redemption adds a page and ends none.** Every page keeps its own cookie,
  page key and nonce, and lives eight hours from its own exchange. Redemption
  is still one message to the actor, so a ticket is still redeemed once.
- **A principal holds at most four live pages per session.** The bound is
  `ui_sessions.max_pages`, and `ending.max_pages` is the same number, because
  the words a page shows name it. The bound is on pages in the actor's table, not on
  sockets: one page's secrets can open several sockets, as before this change,
  and the root's admission capacity bounds those. While its browser is
  connected a page holds a socket, a relay process and a lane of up to 300
  rows. A page that ends, by its deadline or by displacement, has them torn
  down at its next frame, when the gateway revalidates it (`check_binding`),
  so displacement frees them as late as expiry does. Four is an observer tab, an operator tab, a second device and a spare. Pages of another
  principal or of another session are not counted. An expired page is not
  counted either, at its deadline rather than at the next sweep.
- **At the bound, the oldest page ends and the new one opens.** The daemon
  never learns that a tab was closed: a reload closes the page's socket and
  reopens it with the same cookie, key and nonce, so a closed tab's page stays
  live until its eight hours end. A refusal at the bound would lock a person
  out of a long-running daemon after their fifth `loom ui` of the day with
  nothing to close. Ending the oldest keeps the newest four, which are the ones
  a person can still be using. Order is by a serial the actor assigns, not by
  time, since two pages can open in one millisecond.
- **"Ended" now means one of three things**, and the daemon still cannot say
  which: the page's eight hours ran out, the daemon restarted, or it was the
  oldest at the bound. `PageEnded`'s advice says all three and names the bound;
  the table under "The endings" carries the new words. No ending was added, and
  a refused redemption still answers `LinkExpired` as before.
- **Unchanged:** the 60 second single-use ticket, the eight hour lifetime, and
  the Operator cap. Each page's ceiling comes from its own link, so an observer
  page and an operator page of one principal stay what they were minted as, and
  the ceiling still caps the membership role and never grants one. Every frame
  still re-authenticates the credential that minted the page, so revoking that
  credential ends all of its pages at once.

### What a key can do

A stolen key gets exactly one page, and this change does not widen that. What
one page's cookie, key and nonce admit is unchanged: the cookie is `HttpOnly`
and scoped to its key's path, `keyed` and `admits` compare that page's own
digests in constant time, and another page's key or nonce is refused
(`a_page_admits_only_its_own_key_and_nonce_test`, and the two-page route test
under Verification). Holding several pages gives no page a reach into another. Nor
does a stolen page mint pages: a ticket comes only from the principal's own
control connection, so the number of pages an attacker can hold is the number
of secrets they stole, at most the pages the person opened.

What changes is one incidental property of the old rule. Redeeming a fresh link
used to cut off a page the person suspected was copied. It no longer does.
Revoking the credential ends every page it minted, and a page expires in eight
hours; a person who suspects theft revokes.

### What was considered

- **Keep replacement, and add a flag to keep the others.** It leaves the
  surprising behaviour as the default and is not what the owner ruled.
- **Refuse the redemption at the bound, with its own ending.** Built first and
  dropped for the lockout above: no signal frees a place before eight hours, so
  the advice to close a page would be untrue.
- **Free a place when its socket closes.** It needs a grace period to tell a
  reload from a closed tab, and a timer and a pending-close entry per page in
  the actor. A page outliving its tab is the common case, and its cost is a
  place among four that the next link takes over, which is cheap.
- **A bound per principal across sessions, or per daemon.** A principal's
  sessions are already limited by its memberships, and a per-session bound is
  the one a person can predict.
- **A configurable bound.** No case has been made for another number, and a
  setting would need documenting and testing at its extremes.
- **Ending the oldest by time.** Two redemptions in one millisecond would tie.

### Cost

- A fifth page ends the oldest without asking. A person with five useful tabs
  loses one, and that tab shows `PageEnded`, which says why in general and not
  which cause it was.
- A page can outlive its tab by up to eight hours and hold a place until
  displaced. Its socket is gone; the table entry is a few hundred bytes.
- Several operator pages of one principal can each send a prompt or decide an
  approval. The gateway already admits several attachments of one principal,
  as several terminals do, and orders their commands as it does theirs.
- A stolen page cannot be cut off by opening a new link.

### Verification

`ui_sessions_test` shows that a redemption ends no other page, that a principal
holds four and the fifth ends only the oldest, one at a time, without touching
another principal's or session's pages, and that a page expires alone at its
deadline and frees its place before any sweep. `ui_relay_test` shows an open
page staying open when a newer link arrives, and the displaced page ending as
`PageEnded` at its next frame. `ui_route_test` opens two pages of one principal
and reads both, then a fifth, and reads the first as an ended page with the
others open, checks that the second page's nonce does not open the first
page's socket, and reloads a page whose cookie names no live page.
`ending_test` pins the advice to the bound and to the eight hours.

## Addendum: strand focus and the session sidebar (2026-09-29)

**Status**: strand focus and the read-only list ACCEPTED under the owner's
brief for issue #569, part 2, and IMPLEMENTED in the same change; opening
another session from the sidebar was a **PROPOSAL** here and is now
IMPLEMENTED, as the rule "Addendum: switching sessions" (2026-09-29) states ·
**Raised by**: issue #569

### Strand focus

**What it is.** Each chip of the agent strip is a button. Pressing it makes
the page show that strand's transcript and address it: the page's
projection, strip, todo panel and composer all read the shared record's
active strand, which the shared step's change of strand moves
(`step.focus`, the terminal's `switch_active_strand` less its surfaces).
The change sends no command. The frames it may queue are reads (a strand's
configuration, the context, the nudges and the goal), which the gateway
already admits from an observer's binding.

**What is admitted.** The observer's message type gains one constructor,
`component.FocusRequested(strand)`. Its message is built by the strip's
view from the strand name the strip was drawn with, so a browser's click
chooses among the chips that exist and cannot name a strand. The observer's
socket (`ui_socket.observer_accepts`) now admits a Lustre `EventFired`
frame of kind 1 and name `click` at `component.older_path`, as before, or at
any path beneath `component.strip_path` (the strip's chip list; `0\t1\t0\t`
when this addendum landed, `0\t3\t1\t0\t` since the redesign's shell moved the
strip into the strand panel, and `0\t3\t0\t1\t0\t` since the panel became
three tabbed panes with the Strands pane first, as the constant says). A path beneath the list
that names no button finds no handler in the runtime and does nothing. Every other frame is dropped as before: another
event name at a chip's path, a click elsewhere, a batch, a frame of another
kind. `page_events_test` pins that the observer's chips are beneath that
prefix and that the operator's page draws them at the same paths.

**Observers can focus and cannot act.** An observer's page still has no
composer and no command constructor. After a focus it follows the chosen
strand read-only, and the gateway's refusal of an observer's mutation and
the lane's own (`session_channel.can_mutate`) stand as before. An
operator's prompt, steer, queue, interrupt and slash commands address the
strand on screen, since the shared step's commands read the active strand.
Nothing new is sendable: an operator could already address any strand the
terminal can.

**Approval cards follow focus.** The cards are drawn for the strand on
screen, so focusing strand B hides strand A's pending cards. A's chip still
shows that it is waiting for input, and focusing A brings the cards back. A
decision travels with the escalation's identity and the sequence the card
was drawn at, and is sent only for the record still pending there
(`operator.drawn`), so no decision lands on the wrong strand.

**A queued send is cancelled.** A focus cancels the lane's unsent frames, as
the terminal's `cancel_pending` does, so a submit or decision still queued
behind the lane is not sent to the new strand. The draft stays in the
composer, now addressed to the new strand, and the "Not sent" line goes to
the shared record's transcript, which the page does not draw.

**A returned prompt.** A prompt the daemon hands back
(protocol-change/038) for another strand of the session is put in the
composer and named in the notice with the strand it was held for and the
strand the composer addresses. It was dropped before, on the reasoning that
the page composed only for `main`; with focus that no longer holds and the
text is its last copy.

**Cost.** The observer's socket admits a second read-only click and parses
it as it parses the first. A press costs a projection of the chosen
strand's window and a re-render of the strip, the lane and the composer's
address, and the strand's first capture may need its history read (the
"Load older" button offers it). A strand that settled and left the strip
cannot be focused from the page; the "settled" chip is not a control.

**Addendum (2026-09-29, issue #569): settled strands are focusable.** The
"settled" chip is replaced by a group of cards, one per settled strand, the
first six, in reverse row order, and a `+n earlier` line of text. Each card is a button inside the
strip's list, so its handler is at a path beneath `component.strip_path` and
the socket admits it as it admits the live cards' clicks; nothing else about
the admitted paths changes. Focus is the same `FocusRequested`, which needs
only that the capture lists the strand, and the capture already lists every
strand. The group is a `details` element the browser opens and closes, so no
new event or state reaches the server. The list's children are keyed by the
fixed words `card-<n>`, `advisor` and `settled`, never by a strand's name.
The marker relay reaches a settled card by its position, which follows the
live cards', and presses it with a script click, which a closed `details`
does not prevent.

### The session sidebar, read-only

**Ruling (owner, 2026-09-29).** The list is shown to operator pages only.
An observer's page lists nothing and draws no sidebar. Switching, the
follow-up below, will be offered to operator pages only.

**What it is.** An operator's page lists the principal's sessions, grouped by
workspace and newest first, with the session on screen marked and each
session's residency (resident or saved). The daemon supplies the list with
the read a terminal's session picker uses, `manager.authorized_page`,
called with the digest of the credential the page was admitted under,
which the registry authenticates again on each call. A member therefore
sees only the sessions they hold a membership in, an owner every active
session, and a revoked credential none. The page reads the list when it
opens and again at most every 30 seconds, on a tick the lane already
raises, and draws at most the first hundred.

**What reaches the browser.** For each session: its name, its workspace
path, its creation time (used only to order) and whether it is resident,
drawn as text nodes and a `title`. The entry type has no field for the
database path, the request key or the configuration reference, so none
reaches a page. Session identities stay on the server: they mark the
session on screen and name an unnamed session by its first eight
characters. The sidebar has no link, button or handler, adds no event to
either page, and is the page's last child so that no admitted path moves.
(**Superseded, 2026-09-29:** the sidebar is the frame's second child since the
redesign, and an operator page's rows for running sessions are buttons since
"Addendum: switching sessions". The observer page still has no sidebar.)

**An observer's page is given no list.** An observer page is the one a
person hands to someone who may only watch one session. Its authority is the
smaller of the membership and the link's ceiling, and the names, host paths
and residency of the principal's other sessions are not part of watching
one session. Listing them would widen a stolen observer link from one
transcript to the owner's project list, which the ceiling exists to bound.
`ui_socket.listed_for` returns an empty list for an observer's page without
making the read, and the observer's view has no sidebar. The role tested is
the page's admitted authority, which the router has already capped by the
link's ceiling, so both an observer membership and an observer ceiling
produce an observer page. The component's read on open still runs and
returns at once.

**Cost.** One catalogue query per page per 30 seconds, made in the
component's process, which waits for it (the manager call is bounded at
five seconds and a failure is an empty list). A browser holding an
operator's page sees the names and workspace paths of sessions other than
the one it opened, within the principal's own entitlement; a holder of an
observer's page sees none.

### Opening another session from the sidebar: proposal, not implemented

**Superseded (2026-09-29, see "Addendum: switching sessions"): the owner
ruled on the decision below, and the addendum records what was built.** The
section is kept as written so the reasons behind it stay findable. In
particular the sidebar is no longer without a handler: an operator page's
session rows are buttons, and its sidebar has one.

**Why it is not a change to make in passing.** A page is bound to one
session by its key. Its cookie is scoped to a path that names that session,
so the cookie cannot reach another session's exchange, and the UI session
behind it grants exactly one session (`ui_sessions.Grant.session_id`).
Switching therefore means the page obtaining a way into another session,
and every way to do that mints a credential from inside a page.

**The smallest design that would work.**

1. A row of the sidebar becomes a button on an operator's page only (the
   owner's ruling of 2026-09-29; an observer's page has no list), with one
   handler whose message names the listed
   session. The socket admits a click beneath a fixed sidebar path, as it
   does for the strip.
2. The handler asks the daemon for a ticket for that session with the
   principal's own credential, exactly as `loom ui` does over the control
   socket (`ui.link`), and with a ceiling no higher than the current
   page's. The ticket is single use and expires in 60 seconds. This is
   the new capability: the component gains a `link(session)` function
   beside `sessions()`, and the daemon side calls `ui_sessions.mint` after
   re-authorizing the digest against that session.
3. The component tells the browser to navigate to
   `/ui/sessions/<id>?ticket=<ticket>`. Lustre's server component can
   emit an event to the client, and a small client element (in
   `web_client`, through the DOM binding) would perform
   `location.assign` for a path that matches `/ui/sessions/<id>` only.
   The ticket is in the URL as it is when `loom ui` opens the browser,
   and is never logged.
4. The redemption creates a new UI session for the target session. It
   ends the principal's other page for that session under the current
   one-page rule, which is why this wants the ruling that several pages
   per principal are allowed before it lands: with that rule the new page
   coexists with any page already open there.

**What it changes in the threat model.** A stolen operator page could mint
a ticket for every session of the principal, not only its own, so the page's
one-session bound stops being a bound. An observer page could do it too,
unless the handler is refused for an observer ceiling, which is the
conservative choice and would leave observers with the read-only list. The
ticket would travel through the browser's history and the client's
navigation, and the client element that navigates is the first script that
acts on a value the server chose. None of this is new authority for the
credential's holder, who can run `loom ui` for any session, but it is new
authority for the page.

**Alternatives.** Keep the list read-only and let a row show the command to
run (`loom ui <name>`), which changes nothing in the model and costs a
copy. Or make the row a link to a daemon route that mints a ticket and
redirects, which needs an authenticated request the page's key-scoped
cookie cannot make, so it would need a cookie for the whole `/ui` prefix.
Neither was taken; the second widens the cookie, which the operator
addendum narrowed on purpose.

**Decision needed.** Whether a page may mint tickets for its principal's
other sessions, whether an observer ceiling may, and whether the several
pages ruling lands first.

### Verification

`focus_test` shows a chip moving the page to the advisor and to a reviewer
and back with `main`'s rows restored, the strip marking one strand, an
unlisted or shown strand changing nothing, a focus sending no command, an
observer's focused page still having no composer, chips pressed through
the simulator on both pages, and an operator's prompt, steer and queue
addressing the focused strand. `ui_socket_test` admits a click beneath the
strip's list and drops the list's own path, its siblings, other events at a
chip's path and a batch. `sidebar_test` pins the grouping and its ties, the
read on open and its 30-second spacing, escaping, that the sidebar holds no
handler and adds none to either page, and that an empty list draws
nothing. `ui_socket_test` also shows the catalogue entry carrying none of
the registration's private fields. No browser was in the loop.

## Addendum: the page's session controls, the pending nudges and the peer reply (2026-09-29)

**Status**: PROPOSED, IMPLEMENTED with issue #569, part 2 · **Raised by**:
issue #569 (advisor nudges, peer reply, session actions)

The operator page gains buttons for commands the terminal already runs from a
typed draft, a card for the advisor's pending nudges, and a Reply button on a
peer's message. It adds no event to the socket's accepted list and no
operation to what an operator page may do. The earlier addendum, "the
operator page runs session commands", already let a draft name `/fork`,
`/abort` and `/goal ...`. This addendum only lets a click or a small form
choose them.

### What the page shows and sends

- **Stop.** A button in the dock, always drawn and disabled while the strand
  is idle. It sends `msg.Interrupt`, which is the terminal's Escape
  (`commands.interrupt_active`): the strand's running operation is aborted,
  input queued behind it is held until it settles, and the session stays
  open. The terminal distinguishes stopping an operation from ending the
  session, and the page offers only the first. Ending or closing a session is
  daemon control, which stays in the terminal (the owner's ruling of
  2026-09-27, recorded in `docs/design-notes/step-extraction.md`). The command is not
  `/abort`: `/abort` sends the abort frame and nothing else, and Escape also
  records the interrupt so the composer's queue is held, which is what an
  operator who presses a button wants.
- **The goal.** When the session has a goal, the dock shows the terminal's own
  row for it (`goal_view.row`) and the buttons its status offers: Pause while
  it is active, Resume while it is held or has hit a limit, Clear in every
  state. They send `/goal pause`, `/goal resume` and `/goal clear`.
- **Two forms.** A `<details>` for Fork and one for Set goal, each with one
  text field. The text goes after `/fork ` or `/goal ` and is parsed with
  `command.parse`, as a draft is, so the name, `--budget N` and every limit
  are the command's. The page checks what the parse returned against what the
  form is for: the goal form accepts only a goal or the command's own complaint
  about one, so typing `clear` in it does not unpin the goal.
- **Peer reply.** A peer card in the transcript gets a `Reply to this peer`
  button. The terminal has no command that answers a peer: the model answers
  under the owner's link (protocol 048) by calling `peer_send`, at the
  operator's prompt. So the button drafts the start of that prompt, naming the
  peer, in the composer, through the channel a returned prompt uses (put in an
  empty editor, or after the draft, and never over it), and sends nothing. The
  operator completes it and sends it with Send or Steer.
- **Pending nudges.** A card for what the advisor has queued for the primary
  (the `advisor_pending` observation the terminal draws beside its composer),
  every body received, on both pages. It has no button. The queue has no
  accept or dismiss command: the only operation on it is the read-only
  `advisor_pending`, and the primary's next run start drains it, so seeing a
  nudge neither delivers nor discards it. An accept or a dismiss would be a new
  gateway command and its own protocol change, which this addendum does not
  make.

### Which events the socket carries

None is new. The controls and the Reply button are `click` handlers and the
two forms are `submit` handlers, and `ui_socket.operator_accepts` already
forwards both events for an operator's page. `page_events_test` and
`page_actions_test` pin that the operator page registers only clicks and
submits. An observer's page is unchanged: its message type has no
`Controlled` or `Replying`, it draws no control, no Reply and no form, and its
one handler is still the "Load older" click at `component.older_path`. It does
draw the nudge card, which is text only.

A control's command reaches the shared step as `msg.Control`
(`session_view/commands.control`) and not as `msg.Submit`. `submit` marks a
mutating command as the composer's own, so the lane counts the frame it sends
as a consumed draft and the page empties the editor, and a command that is
consumed at dispatch records `DraftTaken`, which has the same effect. A Fork or a
Clear goal pressed while the operator is typing would discard the
draft. `control` runs the same refusal and the same dispatch, sets no marker
and drops that fact, and the terminal does not call it.

### What a stolen page is worth

Nothing more than the earlier addendum priced it at. A holder of the cookie,
the page key and the nonce could already send `/fork`, `/abort` and
`/goal pause|resume|clear|<objective>` in a draft, and the buttons are the same
commands. `/add-dir` and `/add-write-dir` are still refused, and no control
builds one. Every label on the controls is fixed. The one piece of session
content among them, the goal's row, is a text node. A button's message carries
no session text: the goal buttons and Stop carry nothing, and the Reply button
carries the transcript piece's key, which is the engine's.

### What was considered

- **Accept and dismiss buttons on the nudge card.** The issue asked for them
  "matching the terminal's semantics", and the terminal's semantics are
  read-only. Building them needs a gateway command that removes or delivers a
  queued nudge, which is a change to the frozen wire. Not taken here.
- **Stop as `/abort`.** The same words the composer already accepts. Not taken
  for the reason above: Escape is the terminal's stop, and it holds the queue.
- **Run the controls through `msg.Submit`.** It would clear the composer's
  draft. Not taken.
- **Prefill Fork and Set goal in the composer instead of forms.** The
  composer's element joins a prefill after an occupied draft, so the slash
  command would become the second paragraph of a prompt and be sent to the
  model as text. The two small forms cannot do that.
- **A reply form on the peer card that sends at once.** It would send a prompt
  the operator wrote in a one-line field, without the composer's editor.
  Drafting in the composer keeps the send in one place.
- **A new command that sends a message to a peer.** The peer link is directional
  and owner-granted, and the model holds the tool. An operator command would be
  a second path around that grant. Not taken.

### Cost

- The dock has one more row (the controls), and the nudge card when a nudge is
  queued. Both are capped or drawn at fixed places, and the composer is still
  the dock's last child.
- A reply's draft is appended to the list the composer's element reads, which
  keeps every entry for the page's life. A press adds one short string, and
  the list grows by presses.
- The composer's element decides where a reply goes and the server cannot see
  the editor, so it cannot say whether the reply landed in an empty editor or
  after a draft.
- The page cannot accept or dismiss a nudge, so an operator who wants a nudge
  gone must send a prompt, which drains the queue into the run it starts.

### Verification

`page_actions_test` shows: a pending nudge drawn in the dock above the composer
with every body as escaped text and no button, the same card on an observer's
page with no handler, and the count of nudges the server left out; Reply
putting the drafted prompt in the composer's channel, once per press, escaping
it, sending nothing and refusing a key no piece has, with no Reply button on
an observer's page; the goal's buttons by status, in an arming row; Pause,
Resume, Clear, Stop, Fork and Set goal each sending the frame the same words
typed send, leaving `component.drafts` where it was; Stop disabled while idle
and a second press refused; the Fork form refusing a missing name and keeping
its text, an observer's attachment sending no control, and the goal form
refusing `clear`, `pause`, `resume`, `check ...` and nothing; a form with a
field it does not offer refused; and the operator page's handlers being only
clicks and submits. `step_test` shows a command chosen by a control leaving no
draft fact and moving no draft count.

The visual result, the arming delay on the goal row, the disclosure's open
state and the composer's element taking a reply are left to a hand check in a
browser.

## Addendum: the marker relay (2026-09-29)

**Status**: PROPOSED, IMPLEMENTED with issue #569, step 5 of the web UI
redesign (`docs/design-notes/web-design.md`, sections 3.1 and 6.1) ·
**Raised by**: issue #569

The redesign lets a strand be focused from five places: a dot on the
transcript's timeline, a strand's tag in a row, a strand's card in the panel,
a bar in the sidebar, and a link in the breadcrumb or the strand's own view.
Only the cards carry a handler. The other controls carry a marker, and a
client element clicks the card that has the same number. This addendum
approves that one new thing, a client script that clicks a server-drawn
control, and states what it does and does not change. It adds no event to the
socket's accepted list, no operation to what an observer's page may do, and no
frozen interface.

### Why the controls have no handlers

Lustre names an event handler by its path in the tree, and the observer's
socket admits a click at two paths: `component.older_path` and any path
beneath `component.strip_path`, which is the list of strand cards. If each
dot, tag and link carried its own handler, a page of 300 rows would hold 300
more handlers, and the observer's filter would have to admit a click beneath
the lane. A forged click at one of those paths would then ask for a focus by
a path the filter could no longer tie to a card that exists.

### What was decided

**The marker.** A control that focuses a strand and has no handler carries
`data-loom-focus`, and its value is a number: the position of the strand's
card among the cards as drawn, the listed strands in order and the advisor
last (`web_view/view/strip.positions`). Each card carries `data-loom-card`
with its own position. Position zero is `main`, because the strip always
lists `main` first, so a control for `All strands` is the marker `0`. The
value is never a strand's name or identity, and no session text reaches
either attribute. A strand the page does not list has no card, so a control
for it carries no marker and is words or decoration. A piece of the strand on
screen carries none, because focusing the strand already shown does nothing.

**The relay.** `<loom-shell>` hears a `click` that reaches its centre slot or
its panel slot. It reads one fact from the event, the `data-loom-focus` of the
click's own target, decodes it totally (`shell_rule.relay`: a plain number of
at most three digits, anything else is no request), and presses the card
whose `data-loom-card` has that number with the browser's own `click`. The
press is an ordinary click on the card's ordinary handler, so the server hears
exactly what it hears when a person presses the card, and the shared record's
active strand moves as it always did. Where the position is not zero the shell
also opens the panel if it was closed and shows the Strands tab, where the
strand's own view is drawn; `All strands` leaves the layout alone. A click on
anything else fails the decoder and does nothing. A position with no card
finds nothing to press.

**The strand's view.** While a strand other than `main` is in focus, the
Strands tab draws that strand's own view after the list of cards, and the
stylesheet hides the list and the title. The list stays in the page because
the relay works by pressing a card, and the cards must exist to be pressed.
`main` has no view: focusing `main` is `All strands` (the note's section 3.2,
an owner default).

**The breadcrumb.** While a strand other than `main` is in focus, the
centre's first child is a breadcrumb naming the session and the strand, with
an `All strands` link that carries the marker `0`. Otherwise the same place
holds an empty node. It is the centre's first child so that the transcript's
path is the same in both cases, and that path moved once for it:
`component.older_path` is `0\t2\t1\t0\t0`, where it was `0\t2\t0\t0\t0`.
`component.strip_path` moved when the panel became tabbed (`0\t3\t0\t1\t0`).
Both are constants that `ui_socket` and the tests read, so nothing else
quotes a value.

### What a forged marker or click is worth

Whoever holds a page's socket can already press a card, because an observer's
socket admits that click. A marker adds nothing to that: it names a card that
exists, by position, and pressing it is what the socket already admits at the
card's path. A page script that fires a click on a marker is a script that
could fire it on the card. The server never reads a marker; it reads the
click's path, which is a card's. A marker whose value names no card, or that is
not a number, does nothing, and the value cannot name a strand, an approval or
a decision.

The relay presses one kind of control, a strand card, chosen by a fixed
selector, and never a control it finds by content. No approval card carries
either marker, and a click inside an approval card whose target has no marker
fails the decoder. The relay therefore cannot decide, dismiss or hide an
approval. It can change which strand is on screen, which changes which
approval cards are drawn, and a person could do that by pressing the card
(`docs/design-notes/web-design.md`, section 6.1).

### What was considered

- **A handler on every control, and an observer filter that admits a click
  beneath the lane.** The larger surface, and the one that would admit a click
  the filter cannot tie to a strand that exists. Rejected, as the note
  recommends.
- **A copy of the focus in the browser.** The active strand is the shared
  record's, and a copy would have to be reconciled with it on every patch
  and every reload. The note keeps the record as the one source.
- **A listener on `document`.** The page has no content outside `<loom-shell>`,
  so the element's slots hear every click the relay needs, a smaller claim.

### Cost

- One more single-call export in `internal/dom.mjs`, `click`, declared in
  `internal/ffi_dom.gleam`. `scripts/web_client_js_check.sh` still fails on
  any other JavaScript and on the calls that turn text into markup.
- A pointer press on a marker is two clicks, the marker's and the card's,
  which the server sees as one.
- The shell now listens to `click` on two slots, where before it heard only
  its own buttons. The listener reads one property of the event's target and
  nothing else.
- Focusing from a marker in a browser is checked by hand: the listener, the
  query and the press run only there. The rules are tested on Node.

### Verification

`shell_test` (`packages/web_client`) shows the marker decoded totally, the
layout after a relayed click, `All strands` leaving the layout alone, and the
card selector. `marker_test` (`packages/web_view`) shows a dot's and a tag's
number equalling the card's for the same strand, every marker and card value a
number, no marker on the strand on screen or on a strand the page does not
list, dots as spans and never buttons, the breadcrumb and the strand's view
drawn with the list still in the page, and no handler on any of them.
`page_events_test` shows the observer's and the operator's handler tables
holding only the cards' clicks with markers drawn, and `ui_socket_test` shows a
click at a dot's, a tag's, the breadcrumb's and the back link's paths dropped
and a click at a card's admitted. No browser was in the loop.

## Addendum: the keyboard (2026-09-29)

**Status**: PROPOSED, IMPLEMENTED with issue #569, step 6 of the web UI
redesign (`docs/design-notes/web-design.md`, section 6.2) · **Raised by**:
issue #569

`<loom-shell>` now acts on three keys: Command or Control with `B` hides or
shows the sessions sidebar, Command or Control with Alt and `B` hides or shows
the strand panel, and `Escape` puts the page back on `main`. This addendum
approves that, and it changes a rule the earlier addenda state, so it says
which and why the change is safe. It adds no event to the socket's accepted
list, no operation to what a page may do, and no frozen interface.

### The rule this departs from

`docs/lustre.md` and the addenda before this one say: no key handling and no
focus near an approval card. Only `<loom-composer>` acts on a key, and only on
its own editor. `<loom-follow>` hears a key passively and reads nothing from
it, and its subtree holds no approval card. `<loom-shell>` holds the dock in
its subtree, because the dock is the centre column's footer and the centre is
in the shell's default slot. A key listener on the shell is therefore the first
client element that acts on a key and has an approval card in its subtree. That
is the departure.

The reason for the rule is that no keystroke may decide an approval, dismiss
it, hide it, or take focus from it. The rule is restated so that it says that
directly: **no key acts inside an approval card, and no key decides, dismisses
or focuses one.** A client element may act on a key elsewhere in the page. The
argument that the departure is safe:

- **What the listener can do is three things, and none reaches a card.** The
  two toggles change the element's own layout: a column's width and whether its
  content is inert. Neither column is the centre, where the dock is. `Escape`
  presses the breadcrumb's `All strands` link, which is the click a pointer
  makes, and that changes which strand is on screen and so which approval cards
  are drawn, as pressing the strand's card does (protocol-change/051, the
  addendum on strand focus). It decides nothing. There is no fourth intent:
  `shell_rule.Intent` is a closed type of three constructors, and
  `shell_test` walks all of them.
- **Inside the region of approval cards the rule takes no key at all.** The
  server marks the region `data-loom-approvals`. The listener reads the nodes the
  event passed through, its composed path, and a key whose path includes that
  region is dropped by `shell_rule.intent` before it is matched, whatever the
  key and the modifiers, so not even a toggle acts with focus in a card. The
  tests pass every key of the set and several others, in every modifier set,
  with the region in the path.
- **The listener sends the server nothing and there is no server handler for a
  key.** The operator's tree registers clicks and submits and no key event
  (`page_events_test`, with an approval pending), the operator's socket admits
  only those two names, and the observer's socket admits a click at two paths.
  A key, however the listener were misused, cannot arrive at the daemon as a
  decision or as anything.
- **The listener never takes focus.** No intent calls `focus`. A hidden column
  becomes inert, which takes its content out of the tab order, as pressing the
  button does.
- **The card is not a target of the relay.** The relay presses a strand card
  chosen by a fixed selector, and no approval card carries a strand marker
  (the addendum on the marker relay). `Escape` reaches the breadcrumb's link
  by a fixed selector too.

### What was decided

**Scope.** The listener is on the document, added when the element connects
and removed when it disconnects, so a page that replaces the element leaves
nothing listening. An earlier draft put it on the shell's own frame, on the
reasoning that the page has no content outside the shell. That hears nothing
while focus is on `body`, which is the page's usual state: after a load, after
a click on transcript text or on a dot, and in browsers that do not focus a
button when it is clicked. A listener that hears nothing there would make the
shortcuts work only after the reader had tabbed into the page. The document
hears every key pressed in the page whatever has focus.

The document is a larger claim than the frame, and it is safe for the reasons
above, which do not depend on where the listener is: no intent sends anything
to the session, decides anything or takes focus, the server has no key handler,
and the two places where a key belongs to something else are excluded by where
the key was pressed. That is read from the event's composed path and not from
its target. At the document an event's target is retargeted to the outermost
shadow host, so the composer's editor, which is inside a shadow tree, and a
card inside the page's own tree would both look like the same host. The path
holds every node from the focused one outward, shadow roots included. The
shell reads three facts of each node (its tag, whether it is the approval
region, whether its text can be edited) and `shell_rule.target` decides:
inside the region is `Approvals`, which wins; in the composer, or in any
input, textarea, select or editable text, wherever it is (the Fork and Set goal
forms too), is `Editor`; anything else, `body` included, is `Elsewhere`. The
DOM calls are single-call exports in `internal/dom.mjs` (`get_document`,
`add_listener`, `composed_path`, `tag_name`, `attribute`,
`is_content_editable` and `prevent_default`), and the classification is Gleam,
tested on Node with a path through the region, through the composer's shadow
root, through a field and through `body`. Whether the page has a sidebar is
read from the host's `sidebar` attribute when the key is pressed, since the
browser's action is cancelled or not in the event, before a message could be
reduced.

**The key set.** Exactly these three, and no other key is read. The letter is
matched by `code`, `KeyB`, in both toggles, because Option changes `key` on a
Mac; `Escape` is matched by `key`. Shift is never part of a shortcut, and
`Escape` takes no modifier. A key that is neither `Escape` nor `KeyB` is
dropped by the decoder before the listener looks at where it was pressed, so
typing in the composer costs the shell nothing and the shell reads none of it.

**Where they do not act.** Not while an input method is composing. Not when
the event's default was already cancelled, which is how a handler nearer the
target that took a key keeps it. (The composer cancels the default of the keys
it consumes; its `Escape` that closes the list it only observes, and that key
stays the composer's by the next exclusion.) Not while the browser
repeats a held key, so holding a shortcut does not flicker a column. Not
`Escape` in the composer, so that `Escape` in a draft never changes the focus
of the strand being addressed. Not any key inside an approval card. Not the
sidebar shortcut on a page that has no sidebar, so an observer's page leaves
the browser its own `Ctrl+B`. The toggles do act with focus in the composer's
editor: `B` with a command key means nothing in a plain text field.

**The browser's own action.** The two toggles cancel the event's default,
because browsers bind `Ctrl+B` and `Command+Option+B` to bookmarks. `Escape` is
left alone: the page has no default of it to stop.

**Every control the keys reach is a real button.** The toggles carry their
shortcut in `title` and in `aria-keyshortcuts`, and the breadcrumb says `Esc`.
A shortcut a browser keeps still works as its button, so nothing is
keyboard-only.

### What was considered

- **A listener on the shell's frame.** It never hears a key with focus on
  `body`, which is where the page usually is. See scope.
- **Leaving the toggles out while focus is in the composer.** The design note
  proposed that they act there and this follows it.
- **`Escape` sending a focus event of its own.** A key that changes server
  state would then need a socket event and an admission rule. Pressing the
  breadcrumb's link needs neither, and is the same click a pointer makes.

### Cost

- One `keydown` listener on the document while the element is connected, whose
  callback decodes eight fields of every key press and reads the path only for
  the two keys the rule may read. Other listeners on the page (the composer's,
  the follower's) run before it and are not affected.
- `<loom-shell>` and the composer both act on keys in the composer's editor:
  the composer on its own keys, the shell on `B` with a command key. They do not
  overlap: the composer's keys are Command or Control with Enter, the arrows,
  Tab and Enter, which cancel the default and so are dropped by the shell, and
  `Escape` with its list open, which the composer observes and the shell drops
  because it is pressed in the composer.
- The three keys in each browser are not checked here. `Ctrl+B` is bound to
  bookmarks in some browsers, and a page cannot override every reserved
  shortcut. The design note asks for a hand check of Firefox, Chrome and
  Safari, and it is not done: no browser was in the loop. The button is the
  fallback for any key a browser keeps.

### Verification

`shell_test` (`packages/web_client`) walks the key set and every exclusion:
each of the three keys in each modifier set that counts, every other key in
every modifier set as nothing, the exact modifiers (Shift, a lone Alt, `B`
alone), composition, a cancelled default, a repeating key, the composer's
`Escape`, the sidebar's shortcut with no sidebar, every key inside the
approval region, and that the intents are the three and none decides.
`panel_test` (`packages/web_view`) shows the marker on the approval region and
nowhere else, no strand marker inside a card, the composer and the region as
separate places, and no key handler in the operator's or the observer's tree
with an approval pending. `ui_socket_test` drops a `keydown` frame on the
operator's socket. The listener, the decoder over a real event and the target
lookup run only in a browser and were not run.

## Addendum: the storage decision (2026-09-29)

**Status**: PROPOSED, IMPLEMENTED with issue #569, step 7 of the web UI
redesign (`docs/design-notes/web-design.md`, section 4) · **Raised by**:
issue #569

`<loom-shell>` now keeps the reader's layout in the browser's `localStorage`.
The addendum on the page nonce mentions browser storage once, for the nonce in
`sessionStorage`, and states no rule for anything else stored. This one does.
It adds no socket event, no operation to what a page may do, and no frozen
interface. The only change to a type the daemon fills in is a new field on
`component.Start`, which is described below.

### What was decided

**What is stored.** Two records, and nothing else:

- The layout of one workspace: whether the sessions sidebar is open, whether
  the strand panel is open, and which of the panel's tabs shows. It is one item
  per workspace, `loom.layout.v1.<digest>`, holding a JSON object of three
  words, for example `{"sidebar":"open","panel":"closed","tab":"changes"}`.
- The page's theme, per browser and not per workspace: the item
  `loom.theme.v1`, holding one of the words `system`, `light` and `dark`. The
  Theme button in the bar moves the page from following the operating system's
  setting to light, then dark, then back, by setting or removing `data-theme`
  on the document's root, and a missing or unknown stored word follows the
  system. It is a per-browser preference, so it has no digest in its name.

The owner ruled (issue #569, 2026-09-29) that the focused strand is not saved
or restored: a reload shows `main`. The viewed session is not stored either,
since the page's address names it. **Nothing session-derived is stored.** No
strand name, session identity, path, transcript text or count reaches storage,
and the values the two records hold are words from fixed sets.

**Where.** In `internal/dom.mjs`, through two exports, `storage_read` and
`storage_write`, which each make one call on `window.localStorage` inside a
`try` and answer a `Result`, because storage throws when it is blocked and in
some private windows. They are bound in `internal/ffi_dom.gleam` beside the
other DOM bindings. Every decision about the record is Gleam in
`web_client/layout_rule`: the item's name, the encoding, and the decoding. The
decoding is total. It accepts any string and answers a layout, the default
(both columns open, the Strands tab) for a missing, blocked or malformed item,
and the default for one field that names a word this release does not know, so
a tab a later release removes does not discard the columns saved beside it.
The module imports neither Lustre nor the DOM binding, and its tests run on
Node. The one other read is the saved theme's, in the page script before first paint (see "What the reader sees").

`scripts/web_client_js_check.sh` holds the boundary, as it already holds the
rule that `dom.mjs` is the only JavaScript in the package. It fails on any
`localStorage` use other than `window.localStorage.getItem(` and
`window.localStorage.setItem(`, on `sessionStorage`, `indexedDB`,
`document.cookie` and `cookieStore` anywhere in the package's JavaScript, and
on a Gleam `@external(javascript, ...)` to any file but `./dom.mjs`, so a
component cannot reach storage another way. The page's own scripts under
`assets/`, which keep the nonce in `sessionStorage`, are not the components
and are outside that check.

**The key.** A page names its workspace by a digest: the lower-case SHA-256 of
the workspace's canonical path in hex, which the daemon computes when it admits
the page's socket (`client/daemon/ui_socket`) and hands the component in
`component.Start.workspace_digest`. The frame writes it as the `workspace`
attribute of `<loom-shell>`, left out when the host has none. A path is never an
attribute or a storage key. The element reads the attribute from its own host
when it connects and decodes it totally (`layout_rule.workspace`): anything but
64 lower-case hex digits is no workspace, and a page with no workspace reads no
item and writes none, so it can neither share nor overwrite another's layout.
The digest is not a secret and stores nothing that is: it is a name, and a
script on the origin that reads storage learns which workspaces the browser has
opened and the columns it left open in each.

**What the server learns.** Nothing. The layout is read and written in the
browser, and no message carries it: the element sends the server no event of
its own, and the socket's accepted list is unchanged. The server draws every
pane and every column whether or not the browser shows it, and it never learns
which. `component.Start` gains one field, filled from the registration the page
route has already read, and no wire format, frame or daemon state changes.

**What the scope means.** `localStorage` is scoped to the scheme, host and
port. The daemon binds `127.0.0.1:0` by default, so a restart on a new port is
a new origin with empty storage, and the page starts from the defaults;
`--bind` with a fixed port avoids that. `127.0.0.1` and `localhost` are
different origins and each has its own layout. A page served on another
loopback port cannot read this page's storage, which is the property the page
nonce relies on for `sessionStorage`. The content security policy does not
restrict storage. Tabs of one workspace share the item, and one tab's change
reaches another only when that tab loads.

**What the reader sees.** The layout is applied a frame after the shell
connects: the read runs after the paint, so a reader whose columns are stored
closed sees them open for that frame. The theme is applied earlier, before the
first paint, by `assets/web_view_page.js`. The page's first document holds only
the server component, so the shell does not exist until the socket has opened
and the first render has come back, and a shell-only read would show the system's
theme for that whole wait on every load to a reader who chose the other. The page
script already runs before the shell and before paint, so this one read of
`loom.theme.v1` lives there, in a `try`, and sets `data-theme` only to the
fixed words `light` or `dark`, never to the stored text. It is the one use of
`localStorage` outside `dom.mjs`, and it is outside the package the JavaScript
check scans, like the nonce's `sessionStorage`; the check fails if its item name
differs from `layout_rule.theme_key`. The shell owns every later change.

**How the theme reaches every shadow root.** The attribute goes on the
document's root, because custom properties inherit through a shadow boundary
and nothing else reaches all of the page's roots: the server component's, and
one for each client component inside it. The stylesheet had to change for that
to work. Tailwind writes the dark palette on `:root, :host`, and every shadow
root adopts the stylesheet, so each host declared its own tokens, and a
declaration on a host beats the value the host would inherit; a forced light
theme would have reached the document and no element. The stylesheet now sets
each token to `inherit` in a `:host` rule (unlayered, so it beats Tailwind's
layered one), and writes the light palette on `:root` only, twice: once under
`prefers-color-scheme: light` unless the root says `dark`, and once for
`data-theme="light"`. Forced dark is the `@theme` palette and needs no block.
Headless Chrome, given a page with the stylesheet's token rules adopted into a
shadow root nested in another, resolved every combination of a light or dark
system setting and no, light and dark attribute to the right value at each
depth, and resolved forced light to the dark value at both depths when the
`:host` rule was left out. `scripts/web_client_contrast_check.sh` fails when the
two light palettes disagree, when a token has no `inherit` line, and, as
before, when any text token is under 4.5 to 1 in either theme.

### What was considered

- **Storing the record on the server, per principal and workspace** (Option B
  in the design note). It survives a restart on a new port and follows a
  principal across browsers, and it needs a persistence surface in the daemon,
  a socket event that an observer's page must also send, a decision on who
  writes whose layout, and a round trip for a toggle the browser would still
  apply first. The owner chose the browser's storage. If restarts on a new port
  prove a nuisance, a fixed `--bind` or Option B remains open without changing
  what the elements do.
- **A theme button that swaps light and dark.** It could not say which the
  page shows without asking the browser what the system prefers, and it could
  never go back to following the system. Three states cost one more press.
- **The workspace path as the key.** It is readable in the developer tools and
  in the markup, and the client-component rule keeps attributes to identities
  and numbers.
- **One record keyed by workspace, holding the focused strand and the session
  viewed.** The mockup does that. Neither carries over, for the reasons in the
  design note.

### Cost

- One item of a few dozen bytes per workspace and browser, and one for the
  theme, never cleaned up: a workspace that is never opened again leaves its
  item behind.
- A digest field on `component.Start`, which the tests that build one must
  supply.
- The layout is lost when the daemon's origin changes, and it is not shared
  between a browser's profiles or machines.
- The one-frame flash from the default to the stored layout.
- The stylesheet lists each token three times (the dark palette, the light
  palette twice) and once more for `inherit`. The contrast check holds the
  copies together, and a new token must be added to each.

### Verification

`layout_test` (`packages/web_client`) covers the default on nothing stored, the
default on malformed text of several kinds, an unknown tab, an unknown column
word, a missing field, the round trip of all twelve layouts, and that text which
is not a digest names no workspace. `shell_test` (`packages/web_view`) shows the
frame carries the digest on both pages and none when the host has none.
`web_client_js_check.sh --self-test` plants each storage violation and a stray
binding. `layout_test` also covers the theme: a missing or unknown word follows
the system, the round trip, the cycle, and the root attribute each theme sets.
The element's read and write, the button, and the storage's behaviour in a
private window run only in a browser and were not run; the shadow-root token
check above ran in Chrome on a reduced page and not on the served page.

## Addendum: switching sessions (2026-09-29)

**Status**: ACCEPTED under the owner's rulings of 2026-09-29 on issue #569, and
IMPLEMENTED in the same change · **Raised by**: issue #569, step 11 of the web
UI redesign (`docs/design-notes/web-design.md`, section 3.4)

This turns the proposal in "Opening another session from the sidebar" (the
addendum on strand focus and the session sidebar) into a rule. The owner
ruled that an operator page may open another session that its principal
already holds, from the sidebar, and that an observer page lists nothing and
switches nothing. The addendum on several pages per principal, which the
proposal named as a precondition, has landed. The rulings answer the three
questions the proposal left open: a page may mint tickets for its principal's
other sessions, an observer page may not, and several pages come first.

The change adds no route, no kind of socket event and no frozen interface. It
adds one question a page socket can put to the daemon (may this page's
principal open session S, and if so, a ticket), one field on
`component.Transport` that carries it, one client element, and one argument to
`ui_socket.upgrade`, the ticket table's handle.

### What the page sends

A **switch** is a navigation to a new page, so the page asks the daemon for a
ticket and the browser goes to the ticket's exchange. Two controls ask, and
both are `click` handlers on the operator's page:

- **A sidebar row.** The sessions sidebar is the second child of the page's
  frame, so a row's button is at a path beneath `component.sidebar_path`
  (`0\t1`). A row is a button only for a session that a process runs and that
  is not the one on screen. The session on screen and a saved session are
  text, so the page never offers a press that would do nothing or that the
  daemon would refuse. The button's message is `operator_page.Opening(id)`,
  where `id` is the catalogue's identity, drawn into the tree by the server.
- **A peer message's Open button.** A peer message in the transcript names its
  source session. The page draws `Open <name>` beside Reply only when that
  identity is one of the principal's listed running sessions
  (`component.openable`), and then the button's message and its label are the
  catalogue's entry for it. The peer's own words are the card's head and body
  and are not used for either. A peer that names a session the principal does
  not hold, or a saved one, or that names nothing in the list, keeps the card
  as text. On an observer page the card is text.

Neither control gives the browser a way to name a session. A handler's message
is fixed when the tree is drawn, and the browser's event names only the path
it fired at. Pressing the row of the session on screen, which a forged message
could name, asks for nothing.

**Which sockets admit it.** `ui_socket.operator_accepts` admits a `click` at
any path, as it did, and is not narrowed to the sidebar's path: Lustre
dispatches the event only to a handler the operator page drew there, and a
second list of admitted paths would have to be kept equal to the view. An
observer's socket is unchanged. `observer_accepts` admits a click at
`component.older_path` and beneath `component.strip_path` and nowhere else, so
a click beneath `component.sidebar_path` is dropped. Three layers keep an
observer from switching, and each alone is enough: the observer component has
no message that asks and its view draws no sidebar and no Open button;
its socket drops the click; and the daemon refuses an observer page's request
whatever reached it (`ui_socket.opened_for`).

### What the daemon now admits

For an operator page, `component.Transport.open` runs in the component's
process, and `ui_socket.ticket_for` answers it. Each step is made afresh with
the digest of the credential the page was admitted under, and none is read
from the page:

0. The asking page must still be open, which also yields its deadline for the
   ticket (below). A page that ended but whose socket is still up mints
   nothing.
1. The identity must parse as a canonical session identity.
2. `manager.session_authority` must find a membership of the page's principal
   in that session (an owner holds every active session). It is the check
   `ui.link` makes, so a page can open exactly the sessions its principal could
   already ask `loom ui` for, and a revoked credential or a removed
   membership opens none.
3. `manager.get` must report the session resident. A ticket for a session no
   process runs would end at a socket that is refused with nothing to say why.
4. `ui_sessions.mint_before` issues the ticket with the page's own credential
   digest, its own principal, its own ceiling and its own deadline, and the
   page must still be open when it is asked (below). The ceiling caps the role the new
   page is admitted with and never grants one, so a switch cannot raise what a
   link allowed: a page minted from an operator page is an operator page for a
   session the principal operates and an observer page for one it only
   observes.

The ticket is the existing one: 32 random bytes, single use, valid for 60
seconds, redeemed by the exchange under the same checks. It is minted into the
same table, so `max_pages` and every rule about redemption apply unchanged. The
daemon still writes no record of a switch.

The daemon answers with the ticket's exchange path,
`/ui/sessions/<id>?ticket=<ticket>` (`page.exchange_path`, which `ui.link` now
uses as well), or with one of three reasons.

### What the browser does

The component keeps the address in its model (`component.departure`), and the
operator page always draws `<loom-switch hidden>` as the centre column's last
child, so no path an event names moves for it. The element gets a `to`
attribute once a ticket is minted. Loom's page has no script that hears an
event the server emits (`docs/lustre.md`), so the attribute is the interface,
as `sidebar` and `needing` are the shell's.

`<loom-switch>` (`packages/web_client`) is the one script that acts on a value
the server chose, so it accepts one shape. `switch_rule.target` passes exactly
`/ui/sessions/<canonical session identity>?ticket=<64 hexadecimal digits>` and
refuses an absolute URL, another path, a second parameter, a fragment and a
scheme, and the element does nothing with a value it refuses. On a value it
accepts it calls `location.assign`, one new single-call export in `dom.mjs`. The
navigation is same-origin, so it carries `Sec-Fetch-Site: same-origin`, which
the exchange already allows. The exchange page then replaces itself with the
keyed page (`web_view_enter.js`), so the ticket's address is not left in the
history. The address stays in the attribute until the next switch replaces it.
It is spent after one use and dead after 60 seconds.

The page left behind is not ended. The new page is a new UI session with its
own cookie, key and nonce for the target session, and the cap of four is per
principal and per session, so a switch to B adds a B page and can end only the
oldest of four earlier B pages, never a page of A. Going back adds a page of A
in the same way, so a person who moves between two sessions repeatedly ends
the oldest page of a session only after four more pages of that same session.
The sidebar is drawn on the new page too, and its row for the session left is
the way back.

### What is refused, and how it reads

A refused request mints nothing and changes nothing on either page. The page
words the reason in the composer's notice, in fixed sentences chosen by the
reason (`sessions.reason_words`). Nothing the daemon or a session wrote reaches
the browser.

| Reason | Cause | Says |
|---|---|---|
| `NotHeld` | The identity is not a session's, or the principal holds no membership in it, or the session does not exist, or the page is an observer's. One answer for all of them, so a page learns nothing about sessions it cannot open. | "That session is not available to you." |
| `NotRunning` | The principal holds the session and no process runs it. The row was drawn from a list at most 30 seconds old. | "That session is not running. Resume it from a terminal, then open it here." |
| `Unavailable` | The daemon could not answer: it was starting, stopping or slow. | "The daemon could not open that session. Try again." |

Opening a saved session is not done from the page. It would be a new
capability, the daemon starting a session at a browser's request, and the
owner's rulings do not include it.

### What a stolen operator page is worth now

Before this change a stolen page reached the one session it was minted for. Now
a holder of an operator page's cookie, key and nonce can send the click for any
row the page draws, receive the ticket in the tree the page sends back, and exchange it, so
it reaches every running session its principal holds, at the role the principal
holds there, capped by the page's own ceiling. That is what the credential's
holder could already do with `loom ui --session`, and the ceiling is still opt-in
(`--operate`), and revoking the credential ends every page it minted and stops
every later mint. An observer page cannot mint.

**A chain of switches ends with the page it began from.** A ticket that a
page mints for a switch carries that page's deadline
(`ui_sessions.mint_before`), and the page its exchange creates ends at the
earlier of that deadline and `session_ms` from its own exchange. Without this
a page could renew itself by switching, A to B to A, each exchange giving a
fresh eight hours, and the deadline that keeps a copied cookie from working
past the day would not hold. A ticket from `ui.link` keeps today's rule: eight
hours from its exchange. The daemon also refuses to mint for a page that is no
longer open, so a page that ended but whose socket is still up mints nothing
(`ticket_for`'s first step, answered `NotHeld`). The page never gets a role or a session beyond the principal's
memberships, and a switch adds no authority to the principal. It does remove the
page's one-session bound, which the proposal said it would, and the owner
accepted that for operator pages.

### What was considered

- **A daemon route that mints and redirects.** It needs an authenticated request
  and the page's cookie is scoped to one key's path, so it would need a cookie
  for the whole `/ui` prefix, which the operator addendum narrowed on purpose.
  Not taken.
- **The server emits an event and a script listens.** `docs/lustre.md` records
  that the page has no such script. It would need a listener on the document or
  the server component's element. An attribute needs no listener and follows the
  pattern the shell already uses. Not taken.
- **Re-attaching the lane in the same component.** The design note's section 3.4
  rejects it: each region becomes a reset a change can forget, and it puts a
  second session's authority inside a page whose grant names one.
- **Opening the session in a new window.** A script may open one only from a
  user's gesture, and the press reaches the script through the server, so a
  browser may block it. Not taken.
- **Narrowing the operator socket to the sidebar's path.** Named above.
- **A nonce item per page key, so history Back works.** See the cost. It would
  change both bootstrap scripts and the item name that the daemon's tests pin.
  Not taken here.
- **A per-session sharing permission.** The owner ruled that comes later, and it
  is not built.

### Cost

- One more question a page socket can put to the daemon, and one more use of
  `ui_sessions.mint`: a page that presses many rows mints a ticket for each,
  and the table's `actor.periodic` sweep reclaims them at 60 seconds.
- The tab keeps one nonce in `sessionStorage`, and a switch in the same tab
  replaces it with the new page's. The left page's daemon-side page is
  unaffected and is reclaimed at its own deadline. *Addendum:* `<loom-switch>`
  first used `location.assign`, which kept the left page's entry in the history,
  and Back to it showed the waiting paragraph and did not reconnect, because its
  nonce was gone. It then called `location.replace`, so no entry named a page
  whose nonce was spent, and Back left the session pages. The addendum on
  navigation (2026-10-04) keys the nonce by page and returns to `assign`. The sidebar row of
  the earlier session opens it through a fresh ticket. No rule about tickets,
  deadlines or the operator-only switch changed.
- A saved session is text in the sidebar, marked "saved", so a person who wants
  to open it resumes it from a terminal first.
- The list is read every 30 seconds, so a row can name a session stopped since.
  The refusal says so.
- The stale ticket sits in the page's attribute until the next switch or the
  page's end.

### Also in this change

`<loom-shell>` drew its default layout first and the saved one a frame later,
with the column width transition running, so a sidebar saved as closed slid
shut on every load. The frame now carries a `still` class until the restored
layout has been painted, which the stylesheet reads to turn the transition off
(`shell_rule.Motion`), and a `Settled` message removes it, so the reader's own
presses animate as before. This is browser-only and adds nothing to the wire.
The one-frame flash from the default layout, in the storage addendum's cost, is
unchanged.

### Verification

`switch_test` (`packages/web_client`) holds the address shape: a ticket exchange
for a canonical identity is accepted, in either case of hexadecimal digit, and
an absolute URL, a scheme-relative one, a `javascript:` URL, a second parameter,
a fragment, a wrong-length ticket, a non-hexadecimal ticket, a malformed
identity and a path elsewhere on the origin are refused. `shell_test` covers the
frame's classes. `session_switch_test` (`packages/web_view`) shows a row is a
button only for a running session other than the one on screen and that these
are the only handlers beneath `component.sidebar_path`, that a press asks the
transport for the row's session and a ticket becomes the `to` address on the
hidden element, that each refusal is worded in its own fixed sentence and draws
no address, that the session on screen asks nothing, that a peer message offers
Open only for a listed running session and labels it with the catalogue's
escaped name, and that an observer page draws no sidebar, no Open button, no
switch element and no handler beneath the sidebar's path. `sidebar_test` pins the
sidebar's added handlers. `session_isolation_test` builds a page for one session
and then a page for another in one process, each from a capture holding its own
marker in the top bar, transcript, peer message, todo line, Changes and Trace
tabs, approval card, viewers and strand glances, and shows the second page holds
nothing of the first on either page. `ui_socket_test` shows the observer's
socket dropping a click beneath the sidebar's path and at its neighbours, the
operator's socket admitting one, and `opened_for` refusing an observer without
asking. `ui_route_test`, on a real listener and registry, shows an operator page
getting a ticket for a session its principal holds that exchanges into a page
carrying the page's ceiling while the page left behind stays open, a
principal's missing membership, a session that does not exist, text that is not
an identity, an observer page, and a saved session each refused in the reason's
own word. No browser was in the loop: `<loom-switch>` navigating, the
exchange landing on the new page and the layout restoring without a slide run
only in one and were not run.


## Addendum: images in the transcript and the composer (2026-09-29)

**Status**: IMPLEMENTED in the change that adds it · **Raised by**: issue #569,
the web UI redesign's images milestone (`docs/design-notes/web-design.md`)

The wire already carries images. A user message holds `UserImage` blocks, a tool
result holds `ToolResultImage` blocks, and the terminal attaches and sends
them. The page drew only their `[image image/png]` text rows and could send
none. This addendum records how the page draws them and how an operator's page
sends them, and why the content security policy is unchanged.

The change adds one route, one form field, one client element and one
capability in the UI-session table. It adds no kind of socket event and
changes no frozen Part-1 interface: the daemon's v2 protocol already had
`prompt_content`, and the page sends it through the same command path as the
terminal. Two earlier statements change, and they are named where they occur:
the rule that no `src` comes from the session, and the operator socket's 1 MiB
frame limit.

### The transcript: an image is a same-origin fetch

A row that carries images draws each raster image as a thumbnail after its
text, on an observer's page and an operator's alike. The thumbnail is a
`<details>` around an `<img>`. The browser opens and closes a `<details>`
itself, so a click grows the picture and the page hears nothing: no script,
no handler, and no new event for an observer's socket to admit.

The `<img>`'s `src` is `<session>/image/<row>/<position>`, relative to the
page's own address `/ui/p/<key>/sessions/<session>`. The page key is a secret
the component never holds, and a relative reference resolves against the
address the browser already has, so the browser sends the request to
`/ui/p/<key>/sessions/<session>/image/<row>/<position>`.

- **`<row>`** names the row the image belongs to: the key of the block or step
  that `session_view/turns` gives it, digits, `.`, `~` and `-`
  (`transcript_image.ref`). A step's key has a `/` between its block and its
  call, which a path cannot carry, and the name has a `-` there.
- **`<position>`** is the image's place among that row's images, from zero.

**The policy is unchanged.** `img-src 'self'` has been in the policy since the
proposal, and a request to the page's own origin is what it admits. No `data:`
or `blob:` address is drawn, so neither is added.

**A `src` now comes from the page.** The operator addendum's rule says no
`href`, `src`, `action` or `on*` value comes from the session. The image's
`src` is built from the page's own session identity, the engine's key for a
row and a number. Those are the identities that rule already allows for list
keys and handler messages. Nothing the session wrote, and no image's own
declared type, is in it. The rule stands for every other attribute. The
`alt` is a fixed string, and an image whose declared type is not one of the
four raster types draws no picture and keeps its `[image <type>]` text row.

### The route

`GET /ui/p/<key>/sessions/<id>/image/<row>/<position>`, present only with
`--ui`, answered in this order. Each refusal ends the request.

1. **Host** is loopback, as for every `/ui` route.
2. **Shape.** `<row>` is 1 to 48 characters of digits, `.`, `~` and `-`, and
   `<position>` is an integer from 0 to 255. Anything else is not routed and
   answers `404`, so no request costs the daemon a comparison against a long or
   odd name.
3. **Fetch site.** `Sec-Fetch-Site` is `same-origin` (the page's own `<img>`) or
   `none` (an image opened on its own). `same-site`, `cross-site` and a missing
   header answer `403`, so another page's `<img src>` aimed at the daemon cannot
   have the browser fetch the person's images. The cookie is `SameSite=Strict`,
   so it would not go with such a request either.
4. **The page grant**, the same call the page itself makes: a live UI session
   under this key, for the session in the path, whose credential still
   authenticates and is still a member. `401` or `403` as for the page.
5. **The page's reader.** The daemon asks the page's component whether it drew
   an image at `<row>` and `<position>`. It answers `404` when no socket has
   registered a reader for the page, when the socket's process is gone, when the
   component does not answer within two seconds, and when the lane drew no image
   there.
6. **The bytes.** The daemon checks the image the component holds before it
   answers with it (`web_view/image.serve`): the declared type is one of `image/png`,
   `image/jpeg`, `image/gif` and `image/webp`; the base64 decodes; the size is at
   most 20 MiB, the terminal's own image limit; and the bytes' magic number says
   the declared type. A failure of the type, the decoding or the magic number
   answers `415`, and a size over the limit answers `413`.

A success is `200` with `Content-Type` set to the checked type and
`Content-Disposition: inline`, and the response headers every `/ui` response
carries: the policy, `X-Content-Type-Options: nosniff`,
`Referrer-Policy: no-referrer` and `Cache-Control: no-store`. The type is the
checked one and `nosniff` is on, so the browser draws what the daemon checked
and does not sniff another type from the bytes. SVG is not among the four
because it is markup, and an image the browser rendered as a document from the
page's own origin would run script under it.

**Observer and operator.** Both roles are served. An observer's page draws
pictures, so it must be able to fetch them, and a page reads only images its
own component drew, which are rows of a transcript the page's role already
reads. The route makes no check that depends on the role, and the tests show
both.

**How the daemon reaches the component.** The request arrives in an HTTP
handler that holds the page's cookie and nothing of the component, and the
component holds the lane whose images were drawn. The page socket registers,
under the page's cookie in the UI-session table, a function that sends its own
component a message (`ImageRequested`) with `lustre.dispatch`, and the handler
reads that function back after its own checks (`ui_sessions.register_images`
and `ui_sessions.images`). The message is a Lustre message sent from the
daemon's side. A browser frame decodes to Lustre's own runtime messages and
never to a component's, so no frame can produce one, which is why the observer
component has the message and an observer's socket still admits nothing new.

The component answers from the pieces it draws (`turns.picture`), so the daemon
serves an image only where the page shows one. It reads and changes nothing. A
registration is found only through a live UI session, is replaced by a reload's
new socket, and is dropped by the table's sweep with the page. It costs one
map entry and one closure per open page.

### The composer: one field, in the submit event

An operator's composer draws `<loom-attach name="images" limits="...">`
(`packages/web_client`) inside its keyed editor. The element has an Attach image
button that opens the file picker, listens for a paste into the composer's form,
draws a chip with a Remove button for each image, and reads each file's bytes in
the browser. It is form-associated, so it submits its images under its `name` as
one field, a JSON array of base64 strings, in the same `submit` event as the
draft. Nothing is submitted when it holds none. The event is the one the socket
already admits from an operator (`operator_accepts`), so this adds no event and
no admitted path, and no HTTP route performs a command.

An image is sent as an upload route would send it, so the choice is recorded. An
event carries it and no route does, because a route that took a body would be
the first place a page's cookie alone could send a command, and the operator
addendum's rule is that a command reaches the daemon only as an event on a socket
opened with the cookie, the key and the nonce.

**The limits.** They are the terminal's count and a lower byte total, bounded by
what one frame carries:

| Limit | Value |
|---|---|
| Images per prompt | 4, the terminal's `composer.max_image_attachments` |
| Bytes of images per prompt, before base64 | 8 MiB (the terminal admits 20 MiB) |
| Types | PNG, JPEG, GIF and WebP |
| An operator page's inbound frame | 12 MiB, up from 1 MiB |
| An observer page's inbound frame | 64 KiB, unchanged |

The operator addendum said image prompts would need the frame limit raised
under their own review, and this is that review. Eight MiB of images is 10.7 MiB
as base64 text, and a draft of at most 256 KiB and the event's own framing come
to less than 12 MiB. One such submit is held at once as the frame, the Lustre
event's string, the parsed images, their decoded bytes and their canonical
re-encoding, five copies and about 60 MiB at its peak. The operator class was
charged 40 MiB (its 32 MiB message limit and 8 MiB of delivery), which did not
cover that. An operator's page is therefore admitted under its own connection
class, `PageOperator`, charged `root.operator_peak`, 64 MiB. Only page sockets
change: an observer, the control connection, a claim and a terminal operator
keep their classes and charges (`Operator` is still 40 MiB), and the daemon's
default budget still holds twelve terminal operator and control pairs. The
frame limit and the image caps are unchanged. The frame limit is per socket, so it does not raise
the number of sockets, which the root's capacity bounds as before.

**The daemon checks every image, and the browser is not trusted.**
`web_view/image.admit` runs in `component.submit` before anything is sent:

- more than 4 images, or a total over 8 MiB, is refused;
- an image whose base64 does not decode is refused;
- an image's type is read from its own magic number, and anything but the four
  raster types is refused. The browser's declared type is never used. The
  element checks the declared type, the count and the sizes first, so a file that
  would be refused is not read into memory, but a declared type is a guess from a
  file name and this check is the authority;
- one bad image refuses the whole prompt with a notice, and nothing is sent;
- the base64 sent on to the provider is the canonical encoding of the bytes that
  were checked, and never the browser's text.

The composition decoder refuses an `images` field that is not an array of
strings, a repeated `images` field, and every other unknown field, as it did.
Empty text with images is a prompt. A steer carries no images, as in the
terminal, where an image is new prompt content and never live-turn steering. A
session command with images is refused by the shared step, which has nowhere to
put one. The page keeps no attachments between submits: each submit's images are
set for that one step and cleared after it whatever it decided, so a refused
submit whose element still holds its images sends them once with the next submit
and never twice.

**Per role.** An observer's page draws no `<loom-attach>`, has no `images` field
in a form, and its socket drops every submit, so an observer sends nothing. The
gateway refuses a mutation from an observer's binding whatever reaches it, as it
always has.

### What a stolen page is worth now

An operator's page could already send any prompt. It can now send up to 8 MiB of
images with one, which is one more thing the credential's holder could already do
from `loom` in a terminal. An observer's page can read images it could already
read as text rows, and the route serves an image only to a request that carries
the page's cookie and key and a first-party fetch site, and only if the page's
component drew it.

### What was considered

- **`img-src data:`, with the bytes in the page.** It loosens the policy, puts up
  to 20 MiB per image in every patch, and makes the bytes session content in an
  attribute. Not taken, by the standing rule.
- **`blob:` URLs made in the browser.** It needs the bytes in the page first and
  a script that turns them into a URL, and it loosens the policy. Not taken.
- **An address by the image's digest.** The address would need a hash of every
  image on every render, and a lookup by digest would let a page ask for an image
  by content, including one it did not draw. The name of a row and a place is
  cheaper and is what the page drew. Not taken.
- **The daemon reads the durable store.** A resident holds the gateway's address
  and no store handle (`serve.Resident`), and a second reader of the session's
  database from an HTTP handler is a second owner of it. Not taken.
- **A new v2 command that reads an entry.** It is a change to a frozen Part-1
  interface for a read the component already holds in memory. Not taken.
- **An upload route for the composer.** Named above. Not taken.
- **A click handler for the thumbnail.** It would give an observer's socket a
  second admitted path, and the browser already opens a `<details>`. Not taken.
- **Sniffing the type from the bytes in the browser too.** It would repeat the
  daemon's check in a second language with nothing to keep the two equal. The
  element checks the declared type and the daemon reads the bytes. Not taken.

### Cost

- A page's socket registers a closure in the UI-session table, and a request for
  an image waits up to two seconds for its component. A page with images draws
  each thumbnail with its own request, and the browser loads them lazily.
- The operator socket's frame limit is 12 MiB where it was 1 MiB. A page that
  sends a frame that size holds it in memory for the duration of the decode and
  the command, on the class's existing reservation.
- The bytes of an attached image are in the browser's memory as base64 while the
  draft is open, up to about 11 MiB, and in the component's for the length of one
  submit.
- Two pages of the same principal and session share nothing: an image is served
  through the socket that registered for its own cookie, so a second page whose
  socket has not opened answers `404` for every image until it does. A page has
  one nonce per tab, so in practice a page has one socket.
- An image the lane drew and the window then dropped answers `404`, and its
  thumbnail is a broken image until the row leaves the page.
- The thumbnail is a fixed size and does not show the image's own dimensions.
- Every image fetch repeats the page grant's authentication and membership reads,
  as every page request does; a page with many images pays that for each.
- A reader's reply that arrives after the two-second wait is left in the asking
  handler's mailbox until that handler ends, which is one request.
- The daemon serves images up to 20 MiB, the terminal's limit, while the
  composer accepts 8 MiB per prompt, so a page can show an image it could not
  send.

### Verification

`image_test` (`packages/web_view`) holds the address's shape and the row name's
character set and length, the four types drawn and SVG and HTML not, the checks
`serve` makes (a declared type that the bytes contradict, SVG declared as an SVG
and as a PNG, HTML declared as a GIF, text that is not base64, the largest
admissible image served, one byte more refused after the decode, and text longer
than any admissible image refused before it), and the checks `admit` makes for
the composer (the count, the total, each type from its bytes, base64, and the
canonical encoding). `image_view_test` draws a capture holding a prompt with a
PNG, an image declared SVG and one declared with a type holding markup, and a
tool result with a WebP: the PNG and the WebP get thumbnails whose `src` is the
page's own address on both pages, the others keep their escaped text rows, no
`data:` or `blob:` appears, and the component answers for an image it drew and
for no other, through the observer's message and the operator's.
`turns_test` covers the rows that carry images and the lookup.
`operator_page_test` sends an image prompt as `prompt_content` with the image
block, an image alone as a prompt, and refuses HTML that claims to be an image,
text that is not base64, a fifth image, a steer with an image and a slash
command with one, each with its notice, shows a refused submit leaves no
attachment behind, refuses each malformed `images` field, and shows the operator's
composer draws `<loom-attach>` in its form with the daemon's limits while an
observer's page does not. `attach_test` (`packages/web_client`) holds the
element's rules under Node. `ui_http_test` holds the route's shape.
`ui_sessions_test` holds the registry: found through a live page, per page,
replaced by a reload, absent for a cookie that names no live page and for a page
that ended. `ui_route_test`, on a real listener, shows an image served with the
view's headers, for an observer's page and an operator's, `404` before the page's
socket has opened, no reading through another page's reader, `415` and `413` for
what the daemon will not send, the malformed shapes not routed, and a refusal
without the page's own cookie, key and session, from a foreign host, from a
`same-site` or `cross-site` fetch, after the page expired, and after the
credential was revoked. `ui_socket_test` shows both roles' components answering
the daemon's question and a reader answering at once once its socket is gone, and
that the operator's frame holds a full prompt of images.

No browser was in the loop. Thumbnails drawing and growing on a click, the file
picker, a paste of an image, the chips, the form-associated field reaching the
server in a submit, and a 10 MiB frame crossing a real socket run only in one and
were not run.

## Addendum: inviting from the session page (2026-09-29)

**Status**: ACCEPTED under the owner's request of 2026-09-28 on issue #569
("share/invite from the session page"), and IMPLEMENTED in the same change ·
**Raised by**: issue #569 · **Builds on**:
[053](053-owner-admin-and-claims.md), step 1 (the claim flow), and the addenda
above on operators acting from the page and on several pages per principal

An owner's page gains one control, "invite to this session". It makes the
same invitation `loomd access invite` makes, and shows the claim token and the
command the invitee runs, once. Inviting is an owner-only control action and a
page never carries owner authority, so this addendum records the one fixed
path by which a page now reaches it, who sees it, what it can be made to do,
and what a stolen page is worth as a result.

The change adds no HTTP route, no kind of socket event and no frozen
interface. It adds one field on `component.Transport` (`invite`), one event
path (`component.invite_path`), one admission rule in `ui_socket`, one
allowance in the ticket table (`ui_sessions.reserve_invite`), and one client
element (`<loom-copy>`). Part 1 is unchanged: the daemon runs the
`sessions.invite` of 053 through its manager, and the page only asks for it.

**This narrows two sentences of 053 for the session page, and no more.** 053
says an admin page "has no path to a grant" and that a claim "never travels
through a Loom session or page". Those describe the admin page of 053's
phase 4, which is not built and is not changed here. The session page now has
exactly one path to a grant, this one, and the claim it mints passes through
that owner's own page and nowhere else it did not before: not the session's
transcript, not another viewer's page, not a log and not a URL.

### Who sees it

A page draws the control and holds the capability behind it only when both
hold:

- **Its principal is the daemon's owner.** The router read the principal when
  it authenticated the page's credential (`Attachment.principal.kind` is
  `OwnerPrincipal`). The daemon decides this. The page carries no claim about
  who it is.
- **Its role is operator.** The role is the smallest of the membership, the
  ceiling and Operator, as before, so an owner sees the control only on a page
  opened with `loom --ui --operate`. An owner who opened an observer's page has
  none. A page never carries `Owner`, and this addendum does not change that:
  `ui_socket.Role` gains a third value, `Owning`, which is a fact about the
  principal of an operator's page and no grant of authority.

An observer's page, a member operator's page, and an owner's observer page
never see or can send it. Five layers keep it so, and each alone is enough to
refuse the request:

1. `Transport.invite` is `None` unless the page is `Owning`
   (`ui_socket.upgrade` builds the capability, and `admit` puts it in the
   transport). The component draws nothing and ignores the message
   when it holds no capability (`component.invite`).
2. The observer's component has no message that asks and its view draws no
   control, whatever its transport holds.
3. `ui_socket.operator_accepts`, the socket of a member operator's page, drops
   a click at `component.invite_path` and beneath it, alone or in a batch.
   `ui_socket.owner_accepts`, the owner's socket, is the only one that admits
   it. The observer's socket admits no click there either.
4. `ui_socket.invite_for` reads the page's principal again and refuses a
   member (`NotOwner`), and refuses a page that ended but whose socket is
   still up.
5. `manager.administer` authenticates the credential and the daemon epoch a
   second time and requires the owner, in the same dispatch as the mutation.
   It is the last word on who may.

### What the event carries

The control is the third child of the Session pane (`view/session_tab`), so its
handlers are at `component.invite_path`, `0\t3\t2\t2`, and beneath it. There
are three buttons and no field, so the browser has nothing to send but a click
at a path the server drew:

- **Invite an observer** and **Invite an operator** send
  `operator_page.Inviting(role)`. The role is the message's, fixed when the
  tree was drawn. `invites.Role` has two values, `Observer` and `Operator`.
  There is no owner role to name.
- **Hide the token** sends `operator_page.Dismissing`.

The daemon's answer reaches the component as `component.Invited`, dispatched
from the component's own process. No handler carries it, so a browser cannot
send one and cannot place a token in the page. An answer that arrives when no
request is out is dropped.

### The one fixed action

The action is "invite to this session", and it takes no other parameters:

- **The session** is the page's own. A page cannot invite into another
  session.
- **The role** is the button's: observer first, and operator as a second,
  labelled button.
- **The principal** is chosen by the daemon: `guest-` and eight hexadecimal
  digits from the daemon's entropy, named `Guest ` and the same digits. The
  owner learns it from the invitation and uses it to revoke.
- **The lifetime** is one hour (`invites.claim_ttl_ms`). 053's default is a
  day and allows five minutes to a week. An hour is long enough to paste the
  command and the token into a message and for the person to read it between
  other things, and short enough that a token left in a chat window, a
  clipboard history or a scrollback is dead before the day ends. An owner whose
  invitee missed the hour presses the button again, which costs one of the
  credential's invitations (below).
- **The claim** is drawn by `server.claim_enrollment`, the one place a claim
  is drawn. `sessions.invite` on the control endpoint calls the same function,
  so a page's claim has the entropy, shape and digest of any other.

The daemon refuses with a reason, and the page words each in a fixed sentence
(`invites.reason_words`) that holds nothing from the daemon or the session:

| Reason | Cause |
|---|---|
| `NotOwner` | The principal is not the owner, or the page has ended. |
| `TooMany` | The credential has used its invitations for the hour (below). |
| `NotIsolated` | The session still shares its history with its workspace. Isolating a session needs it stopped (`manager.isolate`), so a page, which is attached to a running session, can invite only into one that was isolated and resumed. |
| `Unavailable` | The daemon could not answer or record the invitation. |

### What the page shows, and where the claim lives

The invitation replaces the buttons and shows, in fixed words and the daemon's
values: the role, the principal, the lifetime, the command, the token, and
what to do next. The words say to send both over a channel outside Loom, never
through the session, because text sent there becomes transcript the agent can
read and use first (053, "Claim tokens"). They say to ask the invitee for the
credential fingerprint `loom claim` prints, and to compare it before relying on
the new member, because the page cannot see a credential that has not been
bound yet. They give `loomd access revoke-credentials PRINCIPAL` to void an
unused claim. The command and the token are each in a `<loom-copy>` box with a
Copy button.

The command is `loom claim --addr ws://<Host>/v2/control`. The control
command's reply carries the claim and its lifetime and not `claim_command`,
which `loomd access` builds itself, so the daemon builds it here from the
request's `Host`, which the router already required to be a loopback name
(`ui_socket.claim_address`; `localhost` is written `127.0.0.1` because `loom
claim` refuses `ws` to any other host, and `claim.remote_address` checks the
result). It therefore works on the machine that runs the daemon, which the page
says. A daemon reached through a TLS proxy would need the proxy's address in
the command, which the daemon does not know and a `Host` header the router
refused cannot supply. That is issue #654's, not this change's.

The token exists in these places and no others:

- the daemon's reply, in the component's process;
- the component's state, `View.share = Showing`, from the answer until the owner
  presses Hide, which replaces the state;
- the browser's copy of the page, as the `text` attribute of one `<loom-copy>`
  element, and the owner's clipboard once they press Copy.

It is not logged: nothing on this path writes a log line, and `upgrade_log`
carries only fixed words. It is not stored: the catalogue holds its digest
(`the_claim_redeems_and_only_its_digest_is_kept_test` reads every file under
the state root for the token and finds none). It is not in a URL: it travels
in a socket frame to the one browser. It is not in the session: the invitation
touches the component's view state and never the lane, the shared record, the
outbox or the gateway (`another_page_never_holds_the_invitation_test`). And it
is on no other viewer's page, because each page is its own component and
nothing is published to the session.

Two exposures remain and are not removable from here. The system clipboard
keeps what the owner copied until something replaces it, and a page cannot
clear it. And an OTP crash report of the component or the Lustre runtime while
the invitation shows would write the state to `daemon.log`, which 053 accepts
for the control handler in the same words: the claim is single use and lives an
hour.

`Transport.invite` runs in the component's process, and `manager.administer`
waits up to five seconds. That blocks the page's runtime for as long as the
daemon takes, as `Transport.open` does (and as `Transport.sessions` did until
the addendum on the sidebar's read below moved it into a task), and
`docs/lustre.md`'s checklist prefers a relay process for blocking work. The
call is one registry dispatch, a press is rare and is refused while one is
out, so the addendum follows the switching precedent and does not add a
process.

### Limits

`ui_sessions.invite_limit` is three invitations for each credential in any one
hour (`invite_window_ms`, the claim's own lifetime). The count is kept in the
ticket table, keyed by the credential's fingerprint and not by any page, so
that a reload, a second page or a switch to another session does not reset
it: a program holding a page's secrets could otherwise open a new page for each
three and mint without bound. One reservation is one message, so two pages
asking at once cannot both take the last place. A refusal that minted nothing
gives its place back. An unknown outcome (the registry did not answer, so a
principal may have been made) keeps it spent. One page can therefore mint
three an hour and at most 24 in the eight hours a page lives, and the control
shows at most one invitation at a time: a press while one is out or on screen
is ignored, so one press mints at most one.

A daemon restart resets the allowance. That is acceptable because every page
cookie and ticket lives in the same actor and dies with it, so no page
survives to spend a fresh count.

An owner who needs more invites from a terminal with `loomd access invite`,
which has no such limit and is not a page.

### Why a page may now reach an owner-only action

The control command needs the owner's credential, and a page already holds its
principal's credential digest: the relay attaches with it and the gateway
re-authenticates it on every frame. The daemon runs the invitation with that
digest through `manager.administer`, so the authority a page uses here is the
authority its credential already had, exercised through the path the owner's
own `loomd access` uses. The page adds no role and no ceiling. Its role stays
Operator, the gateway sees nothing of the invitation, and every other page is
unchanged.

What changes is where the action can be started from. 053 declined to build a
page that grants, because a grant outlives the page. This addendum builds one,
on the owner's request, and narrows it as far as the request allows: one
fixed action, for the page's own session, observer first, with a short life, a
count kept for the credential, and a claim that is shown once. It is opt-in in
the way operator pages are: it exists only on a page opened with `--operate` by
the owner.

### What a stolen owner page is worth

The page is worth what any operator page is worth (051, the operator
addendum), for up to eight hours or until the credential is revoked or the
principal's standing changes. To take it, a program needs the cookie, the page
key and the nonce, and the page must be an owner's operator page. With it the
program could already send prompts that run tools and answer approvals.

The new worth is durable. Each invitation is a principal with a membership
that outlives the page. A program that mints an observer invitation and
redeems it on `/v2/claim`, which the agent's tools can reach on loopback unless
the session runs with `--network off`, holds a read-only credential until the
owner notices. One that mints an operator invitation holds an operator
credential, and can send prompts and answer the session's escalations after
the stolen page has closed. This is the case 053 named in its argument
against an owner page that can invite: the session's agent takes the page,
invites a principal it controls as an operator of its own session, claims it,
and answers its own escalations from then on.

The design does not remove that. It bounds it: three invitations an hour for
the credential and 24 in a page's life, an hour for a claim to be redeemed,
membership in the page's own session only, and no reach to the owner's other
sessions or to owner authority. It also makes the invitations findable: each
principal is named `guest-` and its digits, and the owner can revoke it with
`loomd access revoke-credentials`. The owner sees nothing on the page itself
when a program mints one, and the listing that would show every principal
(`principals.list`, 053 step 2) is not built yet.

The owner's choices that shrink the exposure are the ones that were already
theirs: to open an owner's page without `--operate`, which has no control, and
to run the session with `--network off`. The operator button is a second,
labelled button and could be removed in a later change without touching the
rest, which leaves a stolen page able to mint only read-only invitations. That
is the owner's call, and this addendum records that the button is where the
worst case lives.

### What was considered

- **The page renders the `loomd access invite` line and never mints.** It is
  053's own fourth option for grants, and it keeps a stolen page to reductions.
  The owner asked for the page to show the claim itself, so this was not taken.
  It stays available as the smaller change if the owner withdraws the request.
- **A separate owner-grade page with its own ticket table, cookie and 15
  minute life (053 phase 4).** A heavier build for a page that grants, and it
  would not change what one stolen page can mint. Not taken.
- **A proposal on the page confirmed in the terminal.** 053 rejected it
  because an agent holding the page could lodge a proposal and then ask the
  owner to confirm it. Not taken.
- **Widening a page's ceiling to Owner.** It would give a page every owner
  action and end the cap this whole series rests on. Not taken.
- **A count kept for the page.** A reload, a second page or a switch would
  each start it again. Kept for the credential instead.
- **053's default of a day.** A token that sits in a chat log for a day works
  for a day. One hour.
- **Letting the owner choose the name, the principal or the lifetime.** Each is
  a field a stolen page could fill and a decoder to keep total. None is needed
  for the action the owner asked for. Not taken.
- **Reading the text for `<loom-copy>` from its children.** Then the copy would
  run after the next paint, outside the press's own turn, where some browsers
  refuse the clipboard. The text is an attribute, which the element checks
  against the exact shape for its subject (a command that is `loom claim
  --addr` and an address made of address characters, a token that is
  `loomclaim_` and 64 hexadecimal digits) and refuses anything else, including
  a newline, which a terminal would run on paste.
- **A relay process for the blocking call.** See above. Not taken.

### Cost

- A page can, for an owner, start a grant. The durable worst case above is
  the price, and it is the owner's to accept, which is what the request was.
- The page holds a claim token in its state while an invitation shows. The
  clipboard and a crash report are the two copies the daemon cannot clear.
- `manager.administer` blocks the owner's page for up to five seconds.
- A session must already be isolated and running. The page says how to
  isolate one and does not do it.
- The command names a loopback address, so an invitee on another machine needs
  the address of the proxy until #654 lands.
- Each invitation is a principal that stays in the catalogue, revoked or not.
  Three an hour is the bound, and the listing that would show them is step 2 of
  053.
- One more socket admission rule, one more transport field and a fifth layer
  to keep in step.

### Verification

`invite_test` (`packages/web_view`) draws an owner's page and shows the control
inside the Session pane, that its two buttons are the only handlers beneath
`component.invite_path`, that a page with no capability draws nothing and
asks nothing whatever message reaches it, that the observer's view draws none
even with a capability in its transport, that each button sends its own role
once, that a second press while a request is out or an invitation is showing
mints nothing, that the invitation shows the command and the token once each and
the words for handing them over, that hiding it removes the token from the page
and from the component's state, that a refusal is worded in its own fixed
sentence and can be tried again, that an unrequested answer is dropped, and
that another page of the same session holds nothing of it.
`ui_socket_test` shows the owner's socket admitting a click at the path and
beneath it and the member operator's socket dropping it, alone and in a batch,
while admitting its neighbours, and a forged click at the path on a member
operator's page redrawing nothing. `ui_sessions_test` shows the allowance: the
limit, the rolling hour, the release, concurrent reservations, and the sweep.
`ui_route_test`, on a real listener and registry, shows an owner's operator
page inviting into its own session and no other with a claim that lives an
hour and a command naming the loopback address, the operator role reaching the
catalogue, which pages the capability is given to (an owner's observer page, a
member operator and a member observer get none), the daemon refusing a member
that reaches it anyway, an ended page inviting nobody, a session that is not
shared refused without spending an invitation, the limit holding across pages of
one credential, and the claim redeeming once and no file under the state root
holding the token or the invitee's credential. `copy_test`
(`packages/web_client`) holds the two shapes `<loom-copy>` copies and the
refusal of anything else.

Mutations, each applied alone and reverted, each fail a named test: the
member's socket admits the invitation path
(`only_an_owners_socket_admits_the_invitation_click_test`); a member
operator's page is given the capability
(`only_an_owners_operator_page_is_offered_the_capability_test`, which pins
`role_of`, since the route tests replace `upgrade` with a stub; the choice of
capability from the role is `invite_capability`, pinned by
`only_an_owning_page_is_handed_the_capability_test`); the allowance
is skipped (`the_limit_is_the_credentials_across_pages_test`); the release of
a reservation does nothing
(`a_session_that_is_not_shared_is_refused_and_costs_nothing_test`);
the component takes an answer nobody asked for
(`an_unrequested_answer_is_dropped_test`); hiding leaves the token in the state
(`hiding_the_invitation_drops_the_token_test`); the copy rule accepts a newline
(`anything_else_is_not_copyable_as_a_command_test`).

Layers 4 and 5 of "Who sees it" are redundant on purpose. The route test
`the_daemon_refuses_a_member_that_reaches_it_anyway_test` pins their combined
outcome and would pass with either removed, because `manager.administer`
refuses the same request with the same reason.
`the_principal_check_refuses_a_member_on_its_own_test` pins layer 4 alone: it
calls `may_invite`, which reaches neither the allowance nor the manager, with
a member, and would get `Unavailable` if the check were removed.

No browser was in the loop. The clipboard write, the control's layout in the
Session pane, and the copy box's look in both themes run only in one and were
not run.

## Addendum: the dock sheds the nudge card, Stop and the Set goal form (2026-10-02)

**Status**: PROPOSED, IMPLEMENTED with the fix-web-ui-advisor branch ·
**Raised by**: the owner ("the web ui is very cluttered on the bottom")

The owner found the dock cluttered: Stop, a Set goal form and the advisor's
pending-nudge card sat above the composer on every page. This addendum records
what left and where the one thing that moved went. It removes no operation
from what a page may do, adds no event to the socket's accepted list, and
touches no frozen interface.

### What changed

- **The nudge card moved to the strand panel.** The advisor's pending nudges
  are now drawn under the panel's three panes, as the aside's last child,
  on the operator's page and the observer's. The card is not a pane: the tab
  rules hide a tab's sibling panes and nothing else, so the card shows
  whichever tab is chosen, which is the point — the queue is the advisor's,
  not one pane's view. Being the aside's last child keeps every path the
  addenda pin: `component.strip_path` (`0\t3\t0\t1\t0`) and
  `component.invite_path` (`0\t3\t2\t2`) are unchanged, since the card is
  after the panes they walk into. The card still has no handler, and
  `view/nudges` is unchanged; only its caller moved. The card is drawn on
  both pages, as before.
- **Stop left the page.** The dock no longer draws a Stop button. Stopping a
  strand's running operation is the terminal's Escape, and a draft naming
  `/abort` is still parsed as a command by the composer, since S5 parses
  every draft as the terminal does. The `Control.Stop` variant and its arm
  (`msg.Interrupt`) are gone from `web_view/component`, since the page drew
  the one caller. What a stolen page is worth is unchanged: it could already
  send `/abort` in a draft, and the button was the same command.
- **The Set goal form left the page.** A goal is pinned by typing `/goal ...`
  in the composer, which the page parses as a command. The `PinGoal` variant
  and its `pinning` arm are gone with the form. The goal row with Pause,
  Resume and Clear stays: those buttons act on a goal that already exists,
  which is when the operator wants them at hand. The Fork form stays for the
  same reason.
- **The observer's centre lost the card and nothing else.** Its children are
  now the breadcrumb, the lane, the todo panel and the read-only bar. The
  todo panel is the card's neighbour in the old order, and removing the card
  moves only the read-only bar, which carries no handler. `older_path` names
  a button inside the lane, which is the centre's second child either way.
- **The dock is now the todo panel, the goal's buttons with the fork form,
  the approval region and the composer.** The approvals still sit directly
  above the composer, and the composer is still the dock's last child, so
  their paths are as the earlier addenda state them. The composer's form
  path moved (the nudges card was the dock's second child), and
  `operator_accepts` admits a submit at any path but the invitation
  control's, so no admission changed.

### What was considered

- **A fourth tab for the nudges.** The queue is the advisor's, and a tab
  would hide it behind the reader's last tab choice. The card under the
  panes is visible on every tab and hides only with the column.
- **The card inside the Session pane.** The pane is the session's own
  figures, and the card would come and go with the tab. Same reasoning.
- **Keep Stop, disabled while idle.** The button was always drawn so it
  never moved its neighbours, but an always-drawn button that is disabled
  most of the time is clutter with a title to read. The owner asked for it
  gone; a draft can still run the command.
- **Keep the Set goal form for parity with the goal row.** The row acts on
  an existing goal; the form creates one, which is rare and belongs in the
  composer where the draft is parsed anyway.

### Cost

- The advisor's nudges are one column away from the composer: an operator
  who wants to know what the advisor queued before typing looks right
  instead of down. The card's heading still names the primary the queue
  drains into.
- A reader who closes the panel sees no pending nudge at all. The column is
  the reader's own browser preference and the server never learns it is
  closed, and nothing else on the page signals a queued nudge: the Strands
  badge counts strands waiting on a decision, not nudges, and the card has
  no badge of its own. On the dock the card was on screen wherever the
  reader had scrolled. Nothing hides the nudges' *existence* — the advisor's
  delivered rows still cross into the transcript when a run drains the
  queue — but a pending one is visible only while the column is open.
  Widening that signal (a badge the shell draws from a count the server
  sends) would be its own change and is not made here.
- Below 980px the panel is one short row of strand cards under the bar
  (132px, scrolling sideways), and the card is hidden there so it does not
  crowd the cards. A narrow reader still sees a nudge when it is delivered,
  as a row in the transcript.
- Stopping a strand from a page now takes a typed draft. The terminal's
  Escape is unchanged.
- Pinning a goal from a page now takes a typed draft, exactly as the
  terminal's `/goal` always did.

### Verification

`page_actions_test` shows the card drawn under the panel's panes with every
body as escaped text and none of it in the dock, the same card on an
observer's page, no card when nothing is waiting, and the count the server
left out; the page drawing no Stop button on an idle or a running strand, no
Set goal form, and the goal's buttons and the fork form still sending their
commands; a refused command wording its refusal each time; an observer's
attachment still sending no control. `page_events_test` and `ui_socket_test`
pin the handler tables and the admissions, which are unchanged.
`operator_page_test` and `component_test` pin the frames, whose dock is now
one child shorter. No browser was in the loop; the card's look in the panel
and its hiding below 980px run only in one.

## Addendum: the advisor's commentary leaves the lane (2026-10-02)

**Status**: PROPOSED, IMPLEMENTED on `web_view/advisor-commentary-rail` ·
**Raised by**: the owner, on the web page's look ("this takes away from the
transcript")

The advisor's commentary — what it said on its own strand while watching the
primary, captured and never sent — was drawn in the primary's transcript lane
as full amber blocks between the primary's own work. This addendum records it
moving out: the lane keeps one quiet line per review, and the bodies live in
the strand panel beside the strands they observe. It adds no event to the
socket's accepted list, no handler anywhere, and no operation: a click on the
hairline is the click the dot beside it already was, and no click reaches the
commentary section at all.

### What changed

- **The lane keeps a hairline, not the body.** Each `Commentary` piece now
  draws one line — the advisor's tag, then the projection's own request label
  without its `Advisor · ` prefix, which the tag already says (`advisor ·
  quiet requested` and its siblings), in the advisor's colour.
  The label names the request only, never a delivery, exactly as the block it
  replaced did; the tool result still owns the verdict's fate. The dot beside
  the hairline carries `data-loom-focus` with the advisor card's position, as
  it already did: the marker relay presses the advisor's card, whose focused
  transcript is where the full bodies have always lived as the advisor's
  ordinary entries.
- **The bodies moved to the Strands pane.** A read-only section under the
  strand cards draws the board's newest items whole — the request label as a
  head, the advisor's text as a body, a `+n earlier reviews` count line when
  the window holds more, and the board's own not-loaded line when the
  captured ancestry is missing an older parent. It is fed by
  `advisor_history.visible`, the same shared rule the lane asks: a board for
  `main` only. The advisor's own focused transcript already holds the same
  words as its ordinary entries, so the section draws nothing while the
  advisor is on screen, and the stylesheet hides it with the pane's `detailed`
  class for the same reason.
- **Nothing new is admitted, and nothing new holds a handler.** The section
  carries no control, exactly as the pending-nudges card does not: the
  commentary changes nothing, and the run that delivers a nudge is the
  primary's next run start, which no click on captured words can cause. The
  observer's page draws the same hairline and the same section, text nodes
  only, and its handler table is unchanged: an observer's page still holds
  only the "Load older" click and the strand cards' clicks.
- **The paths did not move.** The section is the Strands pane's fourth child,
  after the title, the strip's list and the detail view, so
  `component.strip_path` (`0\t3\t0\t1\t0`) and `component.invite_path`
  (`0\t3\t2\t2`) are exactly where the earlier addenda pin them, and the
  section is `element.none()` when the board is empty, so the pane's child
  count never moves and neither does the detail's place.
- **The TUI is unchanged.** It does not draw through `turns`; it consumes the
  row projection directly, and inline full commentary is its only shelf. The
  shared rule the two hosts cannot disagree on is *which strands see the
  commentary* (`advisor_history.visible`), not where each host draws it —
  the same host-appropriate placement the pending-nudges change made: a card
  in the panel here, a band beside the composer there.

### What was considered

- **Drawing the commentary only on the advisor's own transcript.** That view
  already exists and costs nothing, but it answers "what did the advisor say"
  by swapping the centre away from the primary, and the temporal correlation
  — which stretch of the primary's work a review was about — is the one thing
  a focused advisor transcript cannot show. The hairline keeps that
  correlation at one line per review.
- **Expandable commentary rows in the lane.** A handler per row is the exact
  surface the marker relay exists to avoid, and an inline expansion keeps the
  full text in the lane, which is the complaint.
- **A fifth panel tab for commentary.** Commentary belongs with the strands
  it observes, not beside Changes and Session; and a tab hides it behind the
  reader's last tab choice, the same reason the nudges card sits under the
  panes.

### Cost

- The full review bodies are one column away from the timeline they discuss:
  a reader following the primary's work who wants the advisor's reasoning
  looks at the panel, or focuses the advisor for the whole history. The
  hairline keeps the "when" and the panel keeps the "what".
- Below 980px the section is hidden with the panel's short row of cards; a
  narrow reader still sees each review's hairline and can focus the advisor.
- The lane no longer discloses its bounds inline: the heading
  (`Advisor transcript · captured, not sent to primary`) and the not-loaded
  line moved to the panel's section, which carries both facts.

### Verification

`commentary_test` (`packages/web_view`) shows: the lane holding the hairline
with the advisor's tag and the request label, and neither the full body nor
the heading anywhere before the panel; the hairline's dot carrying the marker
the relay presses the advisor's card with, and an observer's handler table
still exactly the four strand cards' clicks; the section in the Strands pane
under the strip with the advisor's whole text as an escaped text node; the
section drawing nothing while the advisor is on screen, while the advisor's
own transcript holds the same words as its ordinary entries; a page without
commentary drawing no section and no hairline; the count and not-loaded lines
worded; the section holding no button and no form; and the operator's page
drawing the same hairline and section. The web client's gates pass unchanged.
No browser was in the loop; the hairline's look beside a lane and the
section's under the cards run only in one.

**Amended 2026-10-04 (`web/b9-strands`)**: the lane draws no commentary row at
all, neither the hairline nor a rule; the panel's section is the record, and
the advisor's dot on a nudge card is the way into its transcript. Below 980 px
the section is hidden (`.pane-strands > section.commentary` is `display:none`),
so there the only record of the reviews is the advisor's own transcript,
reached by focusing its card, which stays in the strip row at 800 px.

## Addendum: the session controls move to the Session tab (2026-10-03)

**Status**: PROPOSED, IMPLEMENTED with the web/b4-dock branch ·
**Raised by**: the web UI critique, round 1 (F22) and round 2 (F41)

The dock held a goal row, its buttons and the Fork form on every page,
beside the todo line and the composer. The design's dock is the todo line and
the composer only. This addendum amends the placement sentence of the addendum
on the page's session controls (2026-09-29), which put them "in the dock,
above the composer", and of the addendum on the dock (2026-10-02), which kept
them there. It adds no event, removes no operation, and touches no frozen
interface.

### What changed

- **The goal's buttons and the Fork form moved to the Session pane.** They
  are one section, `view/controls.session`, drawn as the pane's fourth
  child. The invitation control is the pane's third child
  (`component.invite_path`, `0\t3\t2\t2`), and the section comes after it, so
  that placing it there shifts no path the addendum on inviting pins:
  `invite_test` and `page_events_test` hold the invitation's handlers at their
  path and the new section's at `component.session_controls_path`
  (`0\t3\t2\t3`). Placing the section before the invitation control would
  have moved it to `0\t3\t2\t3`, and the section is therefore the later of
  the two.
- **The dock keeps one goal line, and only while a goal is active or
  paused.** `view/controls.dock` draws the goal's first row of words and the
  one button that steers it (Pause while active, Resume while paused). A
  goal that is complete or limited, and no goal at all, draw nothing, an
  empty node, so the dock's children keep their places. The `arming` row rule
  carries over to both places unchanged: a change of the goal's status is a
  new keyed row and the stylesheet refuses clicks on it for 600 ms.
- **What the socket admits did not change.** The operator's socket admits a
  click or a submit at any path but the invitation control's
  (`client/daemon/ui_socket.operator_accepts`), so the new section's handlers
  were already admitted; the observer's page draws no section and its socket
  admits none. `ui_socket_test` pins both.
- **The dock's children are now the todo panel, the goal line, the approvals
  and the composer.** The goal line is `element.none()` when it draws
  nothing, as the approvals are, so the composer stays the last child and
  the path of its form does not depend on a goal.
- **Reads of the decision ledger.** A decided approval is drawn in the lane
  as a who line (`Owner denied bash`). It is read from the approval ledger
  the page already keeps: the host looks a request up when it leaves the
  pending cut, and the ledger holds the author, the verdict and the tool
  (`approval.decisions`, sixteen at most). The strand the request was raised
  on comes from the pending cell, which the capture held while the request
  waited (`session_view/decisions`). It adds no event, frame or field. A
  request still waiting has no line, and the approval card is unchanged in
  where it sits.

### What was considered

- **Leave the controls in the dock and shrink them.** The goal row and Fork
  are rare actions, and a form that is closed most of the time still costs a
  row and a label on every page.
- **Put the section before the invitation control.** It would shift the
  invitation's pinned path, which the addendum on inviting forbids without
  its own amendment. After it costs nothing, since the Session pane scrolls.
- **Draw no goal line in the dock.** A loop that spends tokens is worth a
  hand on the button without opening a tab; the line is one row, and only
  while it is running or held.
- **Add a transcript record for a decision.** The register already keeps the
  decided escalation, its author and the strand it was raised on, and the
  ledger carries the first two. A second channel would duplicate it.

### Cost

- The goal's Clear button and the Fork form are one tab away. An operator who
  wants Fork opens the Session tab. Below 980px the panel is a short row of
  cards, and the Session pane's controls are reached by choosing its tab and
  scrolling the row.
- A decision's line is placed by the register sequence that committed it,
  which orders it among the transcript's records but gives no clock time, so
  the line says who and what and not when.
- A page that opens after a request was decided never saw it pending, so it
  has no lookup to make and shows no line for it; the ledger is the page's
  own and is bounded to sixteen. The register keeps every decided escalation
  durably, but a metadata cut carries only the pending ones, so a line that
  survives a reload needs the daemon to list decided escalations. That is a
  wire change and is not made here.

### Verification

`page_actions_test` shows the dock drawing the goal line and Pause for an
active goal and Resume for a paused one, nothing for a complete goal or none,
and the Session pane holding Clear and the Fork form after the invitation
control's place; the buttons still sending their commands; an observer's page
drawing no control. `page_events_test` pins the section's handler at
`component.session_controls_path` and none on the observer's page;
`invite_test` still pins the invitation's two buttons at `invite_path`.
`ui_socket_test` pins the admissions. `operator_page_test` shows the decision
line drawn from a rejected and an approved ledger entry for the strand the
page follows and not for another's. No browser was in the loop for the tests;
the drive screenshots under `docs/design-notes/web-design/drive-b4/` show the
rendered dock and Session tab.

## Addendum: the right panel's content (2026-10-03)

**Status**: PROPOSED, IMPLEMENTED with the web/b5-panel branch ·
**Raised by**: the web UI critique, round 1 (F24, F25, F26, F28, F29, F31) and
round 2 (F44, F45, F49)

This addendum records what the strand panel now draws and one place where a
tooltip carries session text. It adds no event to the socket's accepted list,
no handler, no operation and no field on the wire, and it touches no frozen
interface.

### What changed

- **The commentary section is closed by default.** The addendum of 2026-10-02
  says the section is drawn open in the Strands pane. It is now one native
  `details`, closed, whose summary is `Advisor · 3 reviews · last: <first line
  of the newest review>`. Opening it is the browser's, as the settled group's
  is, so the server draws no handler and never learns which state it is in.
  Inside, the newest three reviews are drawn as before, but each body goes
  through the lane's Markdown drawer (`markdown_view`), which keeps this
  document's rule that nothing from the session becomes markup.
- **A `title` attribute may carry bounded session text.** Rule 653 of this
  proposal says no attribute is built from session content. Two tooltips are
  an exception, both an escaped, inert string with no handler, link, style or
  key: a strand card's `title` holds the whole activity text a tool's status
  line left out (`Working · bash` shows, and the command is the tooltip), cut
  to 240 characters, and the strand view's model row holds the whole model
  identifier its shortened name came from. The sidebar's workspace `title` was
  already such a case. A model's text is still never a class, an identifier, a
  key, a `href`, a `src` or an event value.
- **A strand that has never run is a live card.** `agent_roster.listed` lists
  an idle strand with no operation, which is what a fresh fork is until its
  first prompt. Before, it was drawn in the closed Settled group while the
  operator who forked it looked for it. Focus is unchanged: the page that sent
  the fork stays on the strand it was on. The terminal reads the same rule.
- **Changes folds `fs_write`.** A successful `fs_write` is a file of one hunk
  whose lines are all added, read from the call's `content` argument already
  in the page's records and the `path` of the result's details. The file's line
  says `written · 23 lines` where an edit's counts go, and a file the session
  also edited counts as edited. The fold is `session_view`'s, so the terminal
  can draw the same board.
- **The Session tab words what it shows.** The cost row is the figure
  (`$0.12`) under the label `Est. cost`; viewers are one line per principal
  with its roles and page count (`Owner · owner, operator · 3 pages · you`),
  and the total still counts attachments; a board with no live job reads
  `none` with `At the last refresh` as its tooltip.
- **Cards and strand views say more in fewer words.** A card is a 34 px cache
  ring, the name and a status line that begins with the state's glyph; the
  engine's phase `assistant` reads `thinking` and a state word the activity
  repeats is dropped. A strand's own view adds the task, shortens the model to
  its last path segment, says `not reported` for an unknown context, and
  shows the first line of the strand's latest answer under Recent when no tool
  ran.

### What was considered

- **Keep the commentary open and shrink it.** The section pushed the cards to
  the fold on a short session, and its bodies are the advisor's own words,
  which the focused transcript already holds. One summary line costs the
  reader a click for the bodies, and the click is the browser's.
- **Drop the command from the card without a tooltip.** The command is often
  the one fact that says what a strand is doing. Showing it in the line made
  the card unreadable, and hiding it entirely hid the fact; a tooltip is the
  smallest place that keeps it.
- **Focus the new strand on the page that forked it.** Focus is the page's, not
  the server's, and the operator may have meant to stay where they were. The
  card is enough to find the strand and one click focuses it.

### Cost

- Two more attributes hold session-derived text, both inert `title`s Lustre
  escapes. The attributes that carry such text are now exactly these: the
  active strand's identity (a slug of a model-supplied purpose, letters,
  digits and dashes) as the composer's `aria-label` and `placeholder`
  (`operator_page`), the session identity and the workspace path as `title`s
  (`heading`, `sidebar`), and the two tooltips this addendum adds, a card's
  activity text and a model's identifier. Everything else the session wrote
  stays a text node, and a later change that adds another attribute must amend
  this addendum.
- The commentary's bodies are one click further away, and a short summary quotes
  only the newest review's first line.
- A card's activity text is cut at the first ` · ` when the part before it is a
  single word. A model-written summary that happens to begin with one word and
  a middle dot shows only that word, with the whole in the tooltip.

### Verification

`strand_card_test` pins the phase words, the repeated-word rule, the tool name
without its command, the tooltip's cut and the glyphs. `agent_roster_test` pins
that a never-run strand is listed and one that ran is settled.
`changes_view_test` folds an `fs_write` whose content carries markup (kept as
text), bounds a long one and shows a failed or content-free write adding
nothing. `session_summary_test` groups three pages of one principal into one
viewer. `right_panel_test` shows the glyph, the tooltip, a never-run strand
drawn live without a focus change, and the strand view's new rows.
`commentary_test` shows the closed `details`, the summary line and the Markdown
body with markup still escaped. The drive screenshots under
`docs/design-notes/web-design/drive-b5/` show the rendered panel.

## Addendum: navigation, the per-page nonce and Back (2026-10-04)

**Status**: PROPOSED, IMPLEMENTED with the web/b12-navigation branch ·
**Raised by**: the web UI critique, round 4 (F86, F91, F92)

This addendum reverses one rule of the addendum on switching sessions: that
`<loom-switch>` navigates with `location.replace` so that no history entry names
a page whose nonce was overwritten. It adds no route, no event on the socket's
accepted list and no field on the wire.

### What changed

- **The nonce is kept per page.** The tab's `sessionStorage` item is
  `loom-page-nonce.<page key>` (`page.nonce_item` is the prefix), written by the
  exchange page's script for the keyed page it moves to and read by the page's
  own script for the key in its own path. A page the tab left keeps its nonce,
  so Back to it reconnects. The nonce is still delivered once, in the
  exchange's body, and the keyed page's HTML never carries it.
- **`<loom-switch>` navigates with `location.assign`.** Each keyed page is one
  history entry. The exchange page still replaces itself with the keyed page, so
  the ticket's URL is not left in the history. The admin page's bar gains a
  `Home` control, a fixed `<loom-back>` that calls `history.back()`.
- **A spent ticket is a calm page.** A ticket URL that is requested again (a
  reload, an entry from before this change, or an exchange whose script was
  blocked) is answered as before, `401` with the fixed "link expired or already
  used" document, which now carries a Go back control and the `loom ui` copy
  box. It never reaches the engine and says nothing the request carried.
- **The words.** The not-signed-in document names `/ui/claim` as a fixed link
  for a person with no `loom`; no waiting or ended notice draws a backtick; and
  a page with no socket for five seconds draws the ended document's shape
  (`<loom-waiting>`) from fixed words.

### Why Back is now safe

Tickets are still single use and live 60 seconds, and a reused ticket URL
mints nothing: the daemon spends the ticket on the first exchange and answers
every later request with the refusal document. Back to a keyed page is an
ordinary `GET` of that page, which the daemon serves only to the holder of its
cookie, and the page connects only with its own nonce. A page whose UI session
ended answers as it did before, `PageEnded`. The `Home` control mints no
ticket, so the admin page's fifteen-minute deadline cannot be carried to a home
(the reason the earlier ruling left the admin page with no Home control). Nothing
a person could not do by navigating the same tab is newly possible.

### Where a secret is in a URL

Three URLs carry a ticket: `/ui/sessions/<id>?ticket=`, `/ui/home?ticket=` and
`/ui/admin?ticket=`, and the device link, which is the second with a ticket
minted for another browser. None stays in the history of the tab that opens it,
because the exchange page replaces its own entry. If one does (a blocked
script), Back lands on it and it renders the spent-link document above, since
the ticket was consumed. The keyed address `/ui/p/<key>/...` carries the page
key, which is useless without the cookie and the nonce, and `Referrer-Policy`
keeps both from leaving the origin. The bookmark `/ui/l/<key>/home` carries the
login key and resumes only with the login nonce in `localStorage`. No nonce is
in any URL.

### What was considered

- **Keep `location.replace` and show a calm page on Back.** It leaves every
  page a dead end and the admin page with no way home.
- **Store the nonce in the keyed page's HTML.** Anyone holding the cookie and
  the key can fetch that HTML; the nonce exists to be something they cannot.

### Cost

- One `sessionStorage` item per visited page key, held until the tab closes.
- A person who goes Back to a page that ended sees its ended notice, where
  before they left the app.

### Verification

`page_test` pins the spent-ticket document's Back control and the claim link,
that no waiting notice draws a backtick, and the waiting element in the shell.
`ui_route_test` pins that both scripts build the item from the prefix and the
bundle assigns and never replaces the location. `admin_test` pins the bar's
`<loom-back>`.

## Addendum: the session switcher (2026-10-05)

**Status**: IMPLEMENTED in the change that adds it (round 4 of the web UI
critique, section 5 item 4). It adds one client element and one document key
handler. It adds no route, no event on the socket's accepted list and no field on
the wire.

**What changed.** Command or Control and K opens a popover over the page that
lists the sessions the page's sidebar already offers, filters them as the person
types, and opens the highlighted one on Enter or a click. Escape, a press outside
the panel and the shortcut again close it. The element is `<loom-switcher>`
(`web_client/switcher`), drawn after `<loom-switch>` as the centre's last child on
the operator's page and the home, so no admitted path moves.

**It adds no way to the browser's navigation.** The popover reads the sidebar's
`.session-open` buttons from the page, takes each one's name, workspace and
subtitle as text, and on a choice presses that session's own button
(`HTMLElement.click`). The press is an ordinary click on an ordinary handler: the
daemon is asked for a ticket, checks the page's role and the session's
membership, mints it, and `<loom-switch>` navigates as it does for the sidebar.
The switcher holds no address, mints nothing and sends the server nothing. A
button the server has since removed is not pressed. A page with no sidebar (an
observer's) has no row, so the list is empty.

**Session text.** A name, a workspace's last segment and a subtitle are catalogue
and prompt text. The element reads them with `textContent` and draws each as a
text node of its own view; it never assigns one to markup, to an attribute it
reads back, or to the document's address, and the filter compares them as
strings and builds nothing from them (`switcher_rule`, tested under Node with a
name that holds markup). The query the person types is the field's own `value`.

**The key.** This is the page's first handler for a key outside the composer. It
is a single `keydown` listener on the document, one for each connection and
removed when the element leaves the page, and it reads two things: the shortcut,
which it cancels so the browser's own use of it does not also run, and Escape,
which it only observes. It handles no key near an approval card: an approval's
decision is a button the person presses, and the popover opens over the page
without touching it. While the popover is open the query field has the focus and
handles the arrows and Enter, and leaves every other key to the browser.

**What was considered.**

- *A server-drawn list.* The sidebar's list is already on the page, so a second
  draw would be a second source of the same rows and a new event to admit.
- *Navigating from the element.* A navigation needs a ticket, which only the
  daemon mints. Pressing the sidebar's own button is the only route that does not
  copy the ticket mint into a client.

**Cost.** One document listener and one element. The list is read when the
popover opens, so a session created while it is open appears the next time.

**Tests.** `switcher_test` (the shortcut, the arrows and Enter, an input method's
composing keys, the filter and its order, a name that holds markup, the
highlight's wrap), `home_test` (the element is the centre's last child and the
handlers' paths are as they were).

## Addendum: the home's name form (2026-10-05)

**Status**: PROPOSED, IMPLEMENTED with the web/pr10-principal-rename branch ·
**Raised by**: 065's tenth pull request (`principals.rename`)

This addendum adds one event to the home socket's accepted list. It adds no route
and no field on the wire, and it changes no secret, cookie or nonce rule.

### What changed

- **The home's socket admits a `submit` beneath `home.signins_path`.** The account
  panel the person's name opens is the centre's third child, and it holds the "Your
  name" form. `ui_socket.home_accepts`, `home_owner_accepts` and `home_admin_accepts`
  each admit a submit at a path that begins `0\t2\t2\t`, alone or in a batch, and
  nothing else new: the panel's own path, a sibling that shares its digits, any other
  event at the form and a batch with one message outside the panel are dropped as they
  were. The pinned paths (`component.strip_path`, `invite_path`, `older_path`,
  `sidebar_path`, `home.table_path`, `home.signins_path`, `admin.body_path`) do not
  move.
- **The form carries one value.** Its decoder accepts exactly one field named
  `text`; a repeated, missing or extra field refuses the event. The page names no
  principal: the daemon renames the principal the page was admitted for.

### What was considered

- **Admit the submit for a page with the capability only.** The socket's admission is
  chosen when it starts, from the ceiling and the principal; a read-only link draws no
  form, so there is no handler at the path to receive the event, and the daemon
  refuses the request from a page with no capability. A fourth admission rule would
  have named a combination the other two layers already hold.

### Cost

One more region the home socket reads an event from, for every home.

### Verification

`ui_socket_test` pins the admitted and the dropped frames for all three admissions.
`names_test` pins that the form's handler is one submit beneath the panel and that no
path outside the panel moved.

## Addendum: clickable links (2026-10-05)

**Status**: PROPOSED, IMPLEMENTED with the web/clickable-links branch ·
**Raised by**: the owner ("links aren't clickable, should auto show in new tab")

This addendum changes how a Markdown link in a model's answer is drawn. It adds no
route, no socket admission, no event and no field on the wire. It does not relax the
rule that session text is only ever a text node: the server still writes no `href`,
and the one attribute that carries a destination is written by the browser.

### What changed

- **The server sends a link's destination only as text.** A Markdown link, or a bare
  URL the parser autolinks, is drawn as
  `<loom-link><span class="ll-text">label</span><span class="ll-url" hidden>URL</span></loom-link>`
  (`web_view/markdown_view`). Both children are text nodes of the server's own
  elements, with fixed classes and the fixed `hidden` attribute. The earlier drawing,
  the label followed by `(destination)` as text, is gone.
- **A browser element validates the destination and owns the navigation.**
  `<loom-link>` (`web_client/link`) reads the text of its `ll-url` child and passes it
  to `web_client/link_rule.destination`. Only a plain absolute `http:` or `https:`
  address passes: it must start with the scheme in either letter case, hold no
  whitespace, control character, invisible separator or backslash, have a non-empty
  authority with no `@` (so no `user:pass@host`), and be at most 2048 characters. The
  rule is a text check rather than the `URL` constructor, because the constructor
  strips whitespace, drops tabs and newlines and reads a backslash as a slash, so a
  check run on its output would approve text the browser then handles differently.
  `javascript:`, `data:`, `file:`, `vbscript:`, `mailto:` and a scheme-relative
  `//host` are refused.
- **A valid destination becomes a real anchor, drawn by the element.** In its shadow
  root the element draws `<a href target="_blank" rel="noopener noreferrer"
  title="URL">` around a slot that projects the server's label, with a small `↗`
  glyph after it. The new tab gets no `window.opener`. The `title` is the validated
  destination, so a label that differs from the address can be told apart on hover.
  The browser supplies focus, Enter, middle click and "copy link address". This sets
  an attribute on an element the browser component itself drew, from a value the rule
  approved, and never in the server's markup; the server-side rule stands as written.
- **A refused destination leaves the label as plain text.** The element draws the slot
  and, for a destination that is not empty and does not repeat the label, the
  destination in parentheses as quiet text. There is no anchor and nothing happens on
  a click.
  The element watches its own children, so a destination the server patches later is
  validated again.

### What was considered

- **A `role=link` span with a click and an Enter handler calling `window.open`.** It
  needs the same validation and two handlers, and loses middle click, Control or
  Command click, copy-link-address and the status-bar destination, which the anchor
  gives for free. `rel="noopener noreferrer"` gives the same isolation as the
  `noopener,noreferrer` feature string.
- **Writing `href` on the server after the same check.** The check would then run on
  the daemon with the decision in the markup. That reverses the page's rule that no
  session text is an attribute, and it would need to be kept identical to what the
  browser does with the string. Keeping the server's rule absolute and putting the
  one exception in the browser, after validation, leaves a single place to audit.
- **Showing the destination as text beside every link.** It was the earlier drawing.
  It is long and noisy in an answer and does not make the link usable; the hover
  title shows the same fact where the reader looks for it.

### Cost

A link the browser may open needs the client bundle, so a page whose script did not
load shows labels with no links. A destination the rule refuses, a relative path such
as `docs/README.md` being the common case, is drawn after the label as quiet text in
parentheses with no anchor, unless it is empty or only repeats the label, so the
reader still sees where the model pointed. That text is a text node the element
draws from the hidden child's text, cut to 2048 characters. The rule also refuses the
bidi isolates (U+2066 to U+2069), the invisible characters U+2060 to U+2065, U+00AD
and U+061C, which could reorder or hide part of the address in the hover title.

### Verification

`link_test` (run under Node) pins what the rule accepts and refuses, including the
mixed-case `JaVaScRiPt:`, leading whitespace and control characters, `//host`,
credentials and over-length text. `markdown_view_test` pins the server's markup, that
a hostile label and destination are escaped text, and that no `href` or `on*`
attribute appears in it.

## Addendum: the tab icon (2026-10-05)

The web view's pages carry the Loom mark as their tab icon.

### What changed

- **One more fixed asset.** `GET /ui/assets/favicon.svg` is served like the other
  assets: read once at startup from `web_view`'s `priv/static`, answered with
  `image/svg+xml`, `nosniff` and the unchanged policy. The name is added to the closed
  list in `ui_http.route`; any other name under `/ui/assets` is still a 404. Host and
  `Sec-Fetch` checks are the other assets', and no socket admission changes.
- **Every document links it.** Each `<head>` carries
  `<link rel="icon" type="image/svg+xml" href="/ui/assets/favicon.svg">`, a fixed
  literal built from `page.asset_path`, never from a request. The existing
  `img-src 'self'` already allows it.
- **`/favicon.ico` stays closed.** It lies outside `/ui`, so it is a 404 like any
  other path there. A browser asks for it only when a page names no icon.

### Cost

One more file in the asset set, and a daemon whose release lost it refuses to start
with `web view asset favicon.svg is unreadable`, as it does for the others.

### Verification

`ui_http_test` pins the route and that `/favicon.ico` is `Unknown`. `ui_route_test`
serves the asset and compares it with the priv file, with its content type and the
policy. `page_test` pins the link in every document.

## Addendum: the sidebar's read leaves the runtime (2026-10-05)

**Status**: PROPOSED, IMPLEMENTED with the fix/older-latency branch ·
**Raised by**: the owner's recording of a session page during a busy turn,
where a press of "Load older" was not reflected for about thirty seconds

This addendum changes nothing on the wire, in the routes or in what a socket
admits. It changes which process makes one daemon call.

### What changed

- **`Transport.sessions` starts a task and returns.** The sidebar's read of
  the principal's sessions (one registry call, `manager.authorized_page`)
  was made inside the page's Lustre runtime, from the effect that asks for
  it on `Opened` and every `sessions_refresh_ms`. Lustre performs an effect
  inside the runtime process and broadcasts the render only after it
  returns, and the call waits up to five seconds, so a registry busy with a
  turn could hold the page for up to five seconds every thirty, with every
  click, every pushed frame and every patch waiting behind it. The read now
  runs in a weft run of its own (`ui_socket.listed_task`), as a resume, a
  rename and the home's activity read already do, and answers as the
  component's own `SessionsListed`. An observer's page is delivered its
  empty list without a task, as before.
- **`Transport.sessions` takes the function the answer is delivered to**,
  the shape `resume` and `rename` have; it answers no value.
- **The home's three timer-driven reads take the same shape.** `home.Start`'s
  `sessions`, `signins` and `who` ran in the home's runtime from the one
  effect that refreshes the page on open and every `home.refresh_ms`: the
  list is `authorized_page` and `authorized_roles`, the sign-ins one
  registry call and the name one more, four calls of up to five seconds
  each, so up to twenty seconds inside the home's runtime. Each now takes
  the function its answer is delivered to and starts a task
  (`ui_socket.home_task`), answering as `Answered`, `SigninsRead` and
  `NameRead`; the sign-ins and the name are asked once the list has answered
  and was not `Closed`, as before, and the refresh timer is armed from the
  list's answer, so the next interval still starts after the read.

### What was considered

- **A shorter registry timeout.** It would bound the stall and not remove it,
  and the call is correct at its timeout: the registry is allowed to be
  slow, the page is not allowed to wait for it.
- **Leaving the press-time calls in the runtime** (`Transport.open`, `home`
  and `invite` on the session page; `open`, `sign_out`, `sign_out_all` and
  `device` on the home). Each runs only on a press and is refused while one
  is out. The wait is still the whole page's, not the press's: Lustre runs
  the effect before it broadcasts the render, so every frame and click waits
  with it. They stay as they were because a press is rare and the wait is
  one call; the timer-driven reads ran unasked and charged their wait to
  whatever the person did next.

### Cost

One short-lived process per sidebar read, at most one every thirty seconds
per page, and three per home refresh.

### Verification

`sidebar_test` pins that a read which answers late, or never, leaves `Opened`
and the ticks after it returning at once with an empty sidebar, and that the
list lands as `SessionsListed` when the task delivers it. `ui_socket_test`
pins that `listed_task` returns while its read still waits and delivers once
the read answers, and that an observer's page is answered with no read.
`home_test` pins that a list which answers late leaves the home open with
no groups, that the sign-ins and the name are asked after the list and not
after a closed one, and that the timer is armed from the answer.
