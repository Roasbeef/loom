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

`loom --ui [--session <id>]` resolves the daemon through the existing
discovery path (`tui/daemon/bootstrap.resolve`, under `launch.lock`).

- **No daemon is running.** `loom` adds `--ui` to the launch arguments it
  already passes (`bootstrap.Launch.arguments`), so the daemon it starts
  serves the view.
- **A daemon is running and its `hello` names `ui`.** `loom` requests a
  link for the session and prints it. It opens the browser only when the
  person asks with `--open`.
- **A daemon is running and its `hello` does not name `ui`.** `loom`
  prints that the running daemon was started without `--ui`, and that
  stopping it and running `loom --ui` again starts one that serves the
  view. It exits with status 1. It does not stop, replace or relaunch a
  running daemon, because other people's terminals may be attached to it.

`--session` defaults to the session `loom` would otherwise attach to
(`sessions.default`).

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
      body:{path:"/ui/sessions/<id>?ticket=<ticket>", expires_ms:<int>}}
```

The daemon checks the caller's session membership exactly as a
`/v2/sessions/<id>/ws` upgrade does (`manager.session_authority`), and
refuses with `forbidden` otherwise. The ticket is 32 random bytes,
base64url encoded. The daemon keeps only its SHA-256 digest, together with
the principal, the session, the digest of the credential that asked, and
an expiry 60 seconds away. A ticket can be exchanged once. The reply
carries a path, not a full URL; `loom` joins it to the address it
discovered.

### Routes

Present only with `--ui`. `<id>` is a canonical session ID, parsed with
`ids.parse_session_id` before anything else happens.

| Method and path | Purpose |
|---|---|
| `GET /ui/sessions/<id>?ticket=<t>` | Exchange a ticket for a cookie, then `303` to the same path without the query. |
| `GET /ui/sessions/<id>` | The page: a shell holding one `<lustre-server-component>` whose route is the socket below. |
| `GET /ui/sessions/<id>/ws` | WebSocket upgrade for the Lustre transport. One server component per connection. |
| `GET /ui/assets/lustre-server-component-5.7.1.mjs` | Lustre's client runtime, served from the `lustre` application's `priv` directory. |

The session ID is in every per-session path. A later page that shows
several sessions or agents mounts one `<lustre-server-component>` per view,
each with its own `/ui/sessions/<id>/ws` route, and so its own component
keyed by the person and that session. Nothing in this proposal assumes
one session per page.

### Browser authentication

The ticket exchange creates a UI session: 32 random bytes, sent as the
cookie `loom_ui` with `HttpOnly`, `SameSite=Strict` and `Path=/ui`, and
with no `Max-Age`, so it ends with the browser session. The daemon keeps
the cookie's SHA-256 digest mapped to the principal, the credential digest
that asked for the ticket, and the set of sessions granted to it. A second
ticket for another session, presented with the same cookie, adds that
session to the set, which is what a multi-session page will need. UI
sessions live in memory and end with the daemon's epoch.

Each page load and each socket upgrade re-authorizes from scratch:

1. The cookie's digest names a UI session. Otherwise `401`.
2. The UI session's credential digest still authenticates
   (`manager.authenticate`). A revoked or rotated credential therefore ends
   every UI session it created. Otherwise `401`.
3. The session in the path is in the UI session's set, and the principal
   is still a member (`manager.session_authority`). Otherwise `403`.

The upgrade then acquires a parser permit with `root.acquire`, like any
session socket, so the page counts against `max_connections` and the
reserved-byte limit. After admission the gateway's `check` capability
re-runs step 3 on every request and every push, as it does for a
terminal, so a membership revoked while a page is open closes it.

The daemon's owner credential never reaches a browser. The browser holds
a ticket for at most 60 seconds and then a cookie. Both are random values
the daemon generated; neither is derived from a credential, and neither
authenticates anywhere but `/ui`. When the owner uses `loom --ui`, the
page acts as the owner principal on the one session it was granted, and
is capped to read-only in this phase (below).

### Host and Origin checks

Every `/ui` request is refused with `403` unless:

- `Host` is a loopback name (`127.0.0.1`, `[::1]` or `localhost`) with any
  port. The listener binds only loopback, and a browser reaching it
  through a local forward (for example `ssh -L`) presents the forward's
  port. A rebinding attack presents its own host name and is refused.
- On the socket upgrade and the ticket exchange, `Origin` is present and
  equals `http://` followed by the request's `Host`.

Responses carry `Content-Security-Policy: default-src 'self'; connect-src
'self'; frame-ancestors 'none'`, `X-Content-Type-Options: nosniff` and
`Referrer-Policy: no-referrer`.

### Read-only enforcement

Two independent layers. Either one alone keeps the page from mutating.

- **In the daemon, by role.** In this phase the relay's gateway `Binding`
  carries `access.Participant(access.Observer)` whatever the principal's
  membership is, and its `check` caps the resolved authority to the same.
  The gateway already refuses every command outside its `read_only` list
  for an observer, so a mutation frame from the relay is refused however
  it was produced. A later phase lifts the cap for an operator by issuing
  tickets with an operator scope. That is a change to this route's
  policy, not to the gateway.
- **In the component, by type.** The component's message type is the
  lane's arrivals and a tick, plus nothing else, and its view attaches no
  event handlers. Lustre dispatches a browser event only to a handler
  present in the rendered tree, so a browser has nothing to send. The
  component calls no `session_channel.submit`.

### The relay

One process per page socket, in `packages/client`. It holds the
authenticated `Attachment`, attaches to the gateway with
`attach_authenticated_flushing`, and plays the part `session_socket` plays
for a terminal: a frame the lane transmits becomes one bounded
`gateway.connection_request`, whose reply goes to the component as
`connection_event.Incoming`; a frame the gateway pushes arrives on the
sink and goes to the component the same way. One mailbox serializes both,
as in `session_socket`, so a reply and a push never interleave. The relay
detaches when the component shuts the lane (`Shut`) and exits with it.
It is built on `weft/actor`.

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
bounds apply to it.

## Impact

- `client/daemon/main`: parses `--ui` into the daemon configuration.
- `client/daemon/server`: routes `/ui/...` when on; adds `ui.link` and the
  `hello` field; holds the ticket and UI-session tables.
- `packages/client`: the relay, and the Lustre socket handler that
  registers each browser connection with its component.
- `packages/web_view` (new): the component, its model, update and view,
  over `session_view`.
- `packages/tui`: `--ui`, the `hello` field, `ui.link`, and the message
  when the running daemon lacks the view.
- `docs/client-protocol.md` and spec Part 1.6: the conditional routes, the
  `hello` field and `ui.link`.

## Cost

- Part 1.6's statement that the listener has two endpoints becomes "two,
  and with `--ui` the `/ui` routes as well".
- The daemon grows an HTTP surface that serves a page, and with it the
  class of browser attacks this proposal defends against. The flag keeps
  it off by default, and every defence here must have a test before the
  flag ships (ADR-014, "Verification").
- Two more third-party packages ship in the daemon, used only with `--ui`.
- UI sessions are in memory. A daemon restart ends every open page, and
  the person runs `loom --ui` again.
- The skeleton caps every page to observer. A person with operator rights
  sees a read-only page until a later phase issues operator tickets.

## Open

- **Remote access.** A person reaching a remote daemon through a TLS
  endpoint would present a non-loopback `Host`, which this proposal
  refuses. Allowing it needs a configured allowed origin and the `Secure`
  cookie attribute, and is left to the phase that needs it.
- **Browser launch.** `--open` needs a platform command to open a URL
  (`open`, `xdg-open`). Printing the link is the default until that is
  decided.
