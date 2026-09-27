# protocol-change/051: an opt-in web view on the daemon's listener

**Status**: PROPOSED 2026-09-26 · **Affects**: Part 1.6 client protocol
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
c→s: {v:2, id, cmd:"ui.link", body:{session:<canonical-session-id>}}
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

**Status**: PROPOSED · **Raised by**: issue #530, the web view's first
interactive milestone ([ADR-014](../docs/adr/014-second-runtime.md),
"Direction")

The first interactive milestone gives the page a composer and approval
buttons. Its two commands are `Submit(text)`, a prompt to the addressed
strand, and `Decide(approval, choice)`, the answer to one pending
escalation. Both reach the gateway as the same v2 frames a terminal
sends, written by the same engine code (`session_view`'s lane, through
`session_channel.submit`). The proposal above caps every page to observer
and says the later phase "removes the cap wholesale". This addendum
records how the cap comes off, and what else changes because a page can
now act.

Everything here applies only with `loomd --ui`. An observer's page draws
what it draws today and can send nothing, as today.

### What a page is worth now

The proposal above prices a stolen `loom_ui` cookie at "observer access to
the one session the ticket named". An operator's cookie is worth more: it
can send prompts that run tools, and it can approve escalations. The
escalation is the check a person makes before an agent gets more
authority than its policy gives it. So the threat that matters most is the
session's own agent obtaining an operator's cookie and answering its own
escalations. The agent's tools can reach the loopback listener unless the
session runs with `--network off`, and it can put text in front of the
person: in the transcript, in a file, in a URL printed to the terminal.

Three ways an attacker could act through an operator's page, and what
stops each:

1. **Send commands with the person's browser.** A page on another site,
   or on another loopback port, opens a WebSocket to the daemon, or
   submits a form to it. See "Commands over the socket" below.
2. **Take the cookie and act without the browser.** A program that holds
   the cookie can open the socket with any `Origin` it likes, because
   only browsers enforce `Origin`. See "The cookie leaves only for its own
   page" below.
3. **Run script inside the page.** Script on the page's own origin drives
   the page's socket as the person would. See "Nothing from the
   transcript becomes markup" below.

### The role comes from the membership record, re-read on every frame

The relay no longer overrides the role. The binding it attaches with
carries the authority `manager.frame_authority` answers for the minting
credential when the socket is admitted, and its `check` passes the answer
through unchanged. The membership record is the only place the page's role
comes from. There is no ticket scope and no role chosen for the page,
which is the rule the proposal above set for this phase. `Owner` passes
through as `Owner`, because that is what the credential holds. The page is
still bound to one session. Within that session the gateway gives an owner
one thing an operator lacks: worktree bytes. This milestone's page never
asks for them.

The gateway already calls `check` at every request and every push
(`gateway.check_binding`), and refuses the frame unless the principal and
the authority equal the binding's. So a change of role in either
direction, a revoked credential, a removed membership or an ended UI
session (`ui_relay.while_open`) closes the attachment at the next frame.
The page never changes role while it is open. The page's socket then
closes, and a reload admits a page for whatever role the record now holds.

The permit class follows the admitted role, as it does for a terminal
(`server.resident_upgrade` with the membership role instead of the
observer role). The page socket's inbound frame limit does not. It stays
at 64 KiB for an observer, and is 1 MiB for an operator or an owner, not
the terminal's 32 MiB. The page sends Lustre events, and this milestone's
largest is a text prompt. Pasted images, which are what need the terminal's
limit, are not in this milestone.

### Two components, chosen by role at admission

The page socket starts one of two Lustre applications, chosen from the
authority the relay was admitted with:

- **The observer component** is today's component, unchanged. Its message
  type has no command constructor, and its view attaches no event handler,
  so the browser has nothing to send.
- **The operator component** has the same messages plus `Submit(text)` and
  `Decide(approval, choice)`, and its view attaches handlers for the
  composer and the approval card.

The daemon's gateway refuses a mutation from an observer binding however
the frame was produced, as it does today. The component's type is the
second layer: an observer's component cannot produce a command, and no
message can widen its type while it runs. Either layer alone refuses an
observer's command, and the tests check each one on its own.

### Commands over the socket

A command reaches the daemon only as a Lustre event on an established page
socket. No HTTP route performs a command. Every route is a `GET`, and the
policy's `form-action 'none'` refuses form submission from the page.
Opening the socket needs two things a cross-origin page cannot supply:

- **`Origin` equal to `http://` and the request's `Host`, port included**
  (`ui_http.origin_matches`). A page on another loopback port is same-site
  for cookies but not same-origin. The browser sends that page's own
  origin, which does not match, so the upgrade is refused.
- **The `loom_ui` cookie**, which is `SameSite=Strict`, so a cross-site page
  cannot make the browser send it.

Inside the socket, Lustre dispatches a browser event only to a handler in
the tree the component rendered, and a frame that does not decode is
dropped. So a forged event can name only a control the person's own page
shows. `frame-ancestors 'none'` stays, so no other page can frame the
composer or the approval buttons and trick a click onto them.

### The cookie leaves only for its own page

Browsers scope cookies by host and path, not port. The proposal above
records the consequence: any program listening on another loopback port
receives `loom_ui` when the browser requests a `/ui/...` path there. For an
observer's cookie that was an accepted cost. For an operator's it is how
the agent could get the cookie. The agent starts a server on a loopback
port and prints `http://127.0.0.1:<port>/ui/...` for the person to open.
Opening the link sends the cookie, because a navigation opened from outside
the browser counts as same-site.

So the cookie's path becomes unguessable:

- The ticket exchange mints a **page key** (16 random bytes, base16, from
  the same source as the cookie) and stores it with the UI session.
- The cookie is set with `Path=/ui/p/<key>`.
- The exchange page moves the browser to `/ui/p/<key>/sessions/<id>`. The
  page and its socket are served there, and only there:
  `/ui/p/<key>/sessions/<id>` and `/ui/p/<key>/sessions/<id>/ws`. The
  unkeyed page route answers `404`. The exchange stays at
  `/ui/sessions/<id>?ticket=<t>`, and the assets stay at `/ui/assets/<name>`
  and need no cookie.
- A keyed request is refused with `401` unless its key names the UI session
  its cookie names.

The key is not a credential. It authenticates nothing without the cookie,
and the cookie authenticates nothing without the key's path. It does
decide where the browser sends the cookie. A link an agent writes cannot
contain a key it has never seen, and the key is never shown to the agent:
it goes only to the browser, in the exchange's response. This applies to
every page, observers included, so that a page promoted to operator later
cannot be left with the broader cookie. An observer's page is otherwise
unchanged; only its address moves under the key.

A program that can read the browser's profile gets the cookie and the key
together. That is outside what this addendum defends, as it was before;
the session's read scope decides whether the agent's tools can read the
profile.

### Nothing from the transcript becomes markup

Script on the page's origin can drive an operator's socket. The page's
defence is the policy it already carries (`script-src 'self'`, no inline
script, no `unsafe-eval`) together with these rules for the view:

- Session content (entries, tool output, approval text, names) is drawn
  only as text nodes. Lustre escapes these through houdini. The view never
  inserts raw HTML.
- No attribute that loads or navigates (`href`, `src`, `action`) takes its
  value from session content. A path or URL in the transcript is drawn as
  text.

`component_test` checks both by drawing a transcript that holds markup and
a `javascript:` URL, and asserting that the HTML carries them as escaped
text.

### Decisions bind to what was drawn

`Decide` carries the escalation's ID and the sequence it was drawn at, and
the engine encodes it with `approval.approve` or `approval.deny`, which
send `expected_seq`. An escalation that changed after the card was drawn
is refused by the gateway rather than decided. This milestone offers
**allow once** and **deny**. **Allow for this session**
(`approve_for_session`) is left out. A remembered grant outlives the page
that gave it, and a page opened from a stolen cookie could otherwise leave
authority behind that lasts after the page closes.

### What was considered

- **A role scope on the ticket** (`loom --ui` asks for an operator page or
  an observer page). It would stop an operator's routine read-only page
  from carrying operator rights. It adds a second place a role is decided,
  which the proposal above ruled out, and a person who wants a read-only
  page can mint one from an observer credential. Not taken. If the owner
  wants operator pages to be an explicit choice, this is the shape to use:
  a ceiling on the ticket, never a grant.
- **A command nonce in the page, required on the socket.** Whoever holds
  the cookie can fetch the page and read the nonce, so it stops nothing
  the cookie alone does not. Not taken.
- **Operator pages only with `--network off`.** That couples the view to
  the sandbox's policy and refuses the common development setup. The page
  key closes the port leak instead. Not taken.

### Cost

- The Cost entry above on the shared loopback cookie changes. The cookie
  is sent only to paths under its page key, so a listener on another port
  receives it only through a link that already contains the key. A
  program that holds both gets the membership role for up to 8 hours, or
  until revocation, a membership change or a role change.
- Page addresses carry the key, so a bookmarked page address does not
  survive its UI session. It did not work after the session ended before
  this change either.
- The page socket's operator frame limit (1 MiB) is below the terminal's.
  Image prompts from the page will need it raised, under their own
  review.

### Verification

- An operator's page submits a prompt that reaches the daemon, and decides
  an approval.
- An observer's page is refused by both layers, each tested alone. The
  observer component's type has no command, and a mutation frame sent
  through an observer's relay is answered `forbidden` by the gateway.
- Demoting the principal from operator to observer while the page is open
  closes the socket at the next frame, and the reload admits the observer
  component.
- Mutations of the role gate, each applied alone and reverted, each fail a
  named test:
  - the relay caps to observer again;
  - the relay passes `Operator` whatever the record says;
  - the relay's `check` drops the equality with the binding;
  - the socket starts the operator component for an observer;
  - the page key check is skipped;
  - the upgrade's `Origin` check is skipped.
- A keyed route with another UI session's key, or with no cookie, is
  refused, and the unkeyed page route is `404`.
