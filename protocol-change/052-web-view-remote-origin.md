# protocol-change/052: the web view behind a TLS origin

**Status**: PROPOSED 2026-09-26, design only · **Affects**: Part 1.6 client
protocol (the `/ui` admission checks, the `hello` `ui` field, one daemon
flag) and the `loom --ui` launch · **Raised by**: the Open item "Remote
access" in [protocol-change/051](051-web-view-route.md) · **Decision
record**: [ADR-014](../docs/adr/014-second-runtime.md), "Direction"

## Problem

051 serves a read-only page from `loomd --ui` and admits a request only when
its `Host` is a loopback name. A person on the daemon's own machine opens
the page directly, and a person on another machine can reach it today
through `ssh -L`, because the forwarded browser still presents a loopback
`Host`. That covers one person at a time with shell access to the daemon's
host. It does not cover the direction ADR-014 names: a team that watches
the same sessions from their own machines, each as the member the owner
invited, without an SSH account on the daemon's host.

Serving the page to other machines needs four things 051 does not have:

- A TLS endpoint. `docs/client-protocol.md` §2.4 says the daemon binds
  loopback only and terminates no TLS, and that a client on another host
  must come through a trusted TLS endpoint or an authenticated tunnel.
- A `Host` rule that admits that endpoint's name and still refuses a DNS
  rebinding attacker's.
- Cookie, `Origin` and content-security rules that hold on an `https`
  origin, which may share a registrable domain with sites the owner does
  not control.
- A way for a teammate to get a ticket. `loom --ui` mints one over the
  local control socket, which a teammate on another machine cannot use.

## What was considered

### Where TLS terminates

**`loomd` terminates TLS itself.** `mist` can serve TLS from a certificate
and key file. The daemon would bind a routable address, which removes the
invariant in §2.4 that there is no listener on a routable address to
protect. It would also need certificate configuration, reload on rotation
and, in practice, ACME, none of which the daemon has, and every one of
which is new code on the path every request takes.

**A TLS-terminating reverse proxy on the same host, chosen.** The proxy
(Caddy, nginx, or similar) holds the certificate and forwards to the
daemon's loopback listener. `loomd` gains no TLS code and keeps its
loopback-only bind, so the proxy must run on the daemon's host: a proxy on
another machine would carry tickets, cookies and bearers across the network
in clear text. The loopback bind means an off-host proxy needs a
deliberate cleartext relay on the daemon's host (`socat`, `ssh -L`), and
this proposal forbids one. Operators who expose services already run
such a proxy, and certificate management is its job.

### How the daemon knows which names to admit

**Trust `X-Forwarded-Host` or `Forwarded` from the proxy.** The daemon
cannot tell a proxy's header from one a local process wrote, because both
arrive on the same loopback listener. Rejected.

**Accept any `Host` when a flag is set.** This re-opens DNS rebinding,
which is the reason 051 checks `Host` at all. Rejected.

**An allowed-origins list, chosen.** The owner names each `https` origin
the page is served at. A request is admitted when its `Host` is a
loopback name, as in 051, or exactly the host and port of one listed
origin. Every rule that differs between the two cases is decided by which
of the two matched, never by a second input.

### Where the page lives on the proxy's host

**Under a path prefix on a shared host** (`https://example.com/loom/`).
Every other application on that origin could then run script in the
page's origin, open its socket with the person's cookie, and read the
transcript; no header the daemon sets prevents a same-origin script. The
prefix would also move the routes away from the `/ui` path the `hello`
states. Rejected.

**A host name dedicated to the daemon, chosen.** The origin is
`https://<name>[:port]`, the proxy forwards every path on it to the
daemon, and nothing else is served there. This is also what the `__Host-`
cookie prefix requires (below).

### How a teammate gets a ticket

**The owner mints links and sends them.** A ticket is bound to the
principal and the credential that minted it, so a forwarded link makes the
recipient act as the owner, capped to observer. Membership and revocation
would stop meaning anything for the page. Rejected.

**A new invitation flow for browsers.** A browser-only credential would
need its own issue, rotation and revocation, which is the second kind of
credential 051 declined to create. Rejected.

**The teammate's own `loom`, against the remote daemon, chosen.** Most of
this exists already. `sessions.invite` issues a member a bearer and one
session membership. The terminal's remote launch accepts
`wss://<name>/v2/control` for the control endpoint and refuses plain `ws`
to anything but loopback (`tui/daemon.valid_address`). The daemon's `ui.link`
handler checks the caller's membership, not ownership, and records the
digest of the credential that asked, so revoking or rotating the member's
credential, or removing the membership, ends every page it opened. What is
missing is only the client half: `loom --ui` resolves a local daemon and
has no `--addr`.

### Where the ticket travels

The ticket is in the query string of the exchange URL. Through a proxy,
the exchange's request line reaches the proxy's access log.

**Move the ticket to the URL fragment.** Browsers do not send fragments,
so the ticket would reach no log. The exchange would become a script that
reads `location.hash` and posts it, which is a new route with its own
CSRF rules, and a change to 051's loopback exchange as well. Deferred
(see Open).

**Keep the query string and require the proxy not to log it, chosen for
now.** A ticket lives 60 seconds and is spent by the first redemption, so
a ticket in a log is already spent in the normal flow, where the browser
redeems it within a second of being handed it. The residue is a link
minted and never opened. The proxy requirement below closes that residue,
at the cost of depending on configuration.

## Proposal

### Configuration

`loomd --ui --ui-origin https://<name>[:port]` names one allowed origin.
The flag may repeat. At startup each value must:

- use the `https` scheme,
- have a host and nothing else: no user information, path (a lone `/` is
  accepted and dropped), query or fragment,
- not name a loopback host, which 051 already admits,
- come with `--ui`, or the daemon refuses to start.

The daemon stores each origin normalized: the host lowercased, and the
port dropped when it is 443, because that is the form a browser sends in
`Origin` and in `Host`. Without `--ui-origin`, nothing in 051 changes.

The daemon's listener stays loopback-only. A remote deployment runs it on
a fixed port (`--bind 127.0.0.1:<port>`) so the proxy has a stable target.

### Proxy requirements

The proxy is part of the trusted computing base: it holds the TLS key and
sees every byte in clear text. It must:

- run on the daemon's host and forward to the loopback listener;
- serve the dedicated origin and nothing else on it, and forward every
  path, including WebSocket upgrades on `/v2/...` and `/ui/...`;
- pass `Host`, `Origin`, `Cookie` and every `Sec-Fetch-*` header through
  unchanged;
- send `Strict-Transport-Security`, so a browser that has visited once
  never tries the origin over plain `http`;
- keep the `ticket` query parameter out of its access log.

The daemon reads no `X-Forwarded-*` or `Forwarded` header, now or later.

### Admission: one origin per request

The first check in 051, **Host**, becomes a resolution. It yields one of
two page origins, or refuses with `403`:

- `Loopback(host)`: `Host` is `127.0.0.1`, `[::1]` or `localhost` with any
  port. Exactly 051.
- `Remote(origin)`: `Host` equals the host-and-port of an allowed origin,
  compared after the same normalization.

Every later rule is a function of that value, so a remote request can
never receive a loopback cookie or be checked against a loopback origin.

| Rule | `Loopback(host)` (051, unchanged) | `Remote(origin)` |
|---|---|---|
| Exchange `Sec-Fetch-Site` | `none` or `same-origin` | `none` or `same-origin` |
| Upgrade `Origin` | `http://` + `Host` | exactly `origin` (`https://…`) |
| Cookie name | `loom_ui` | `__Host-loom_ui` |
| Cookie attributes | `HttpOnly; SameSite=Strict; Path=/ui` | `Secure; HttpOnly; SameSite=Strict; Path=/` |
| CSP `connect-src` | `'self' ws://<Host>` | `'self' wss://<Host>` |

**`Sec-Fetch-Site`.** The rule does not change, and it matters more:
`same-site` stays refused, so a sibling subdomain of the dedicated name
cannot drive the exchange.

**`Origin`.** The upgrade's `Origin` must equal the configured origin
string byte for byte. An `http://<name>` page, which a network attacker
can serve before HSTS takes effect, presents `http://` and is refused.

**The cookie.** `Secure` keeps it off plain `http`. The `__Host-` prefix
makes the browser refuse the cookie unless it is `Secure`, has no
`Domain` and has `Path=/`, and refuse any cookie of that name set by a
sibling subdomain. That closes cookie tossing: a site on
`evil.example.com` can set a `loom_ui` cookie for `.example.com`, but it
cannot set `__Host-loom_ui` for `loom.example.com`, so it cannot fix a
teammate's page to a UI session of its choosing. `Path=/` is required by
the prefix and costs nothing on a dedicated origin; the `/v2` routes take
only bearers and never read a cookie. A request is looked up by the
cookie name its page origin implies, and the other name is ignored.

**The rest of the policy** is 051's. `frame-ancestors 'none'`,
`form-action 'none'`, `base-uri 'none'`, `nosniff`, `no-referrer` and
`no-store` carry over unchanged.

### The `hello` field

When the view is on and at least one origin is configured, the `ui`
object gains the list:

```
"ui": {"path": "/ui", "origins": ["https://loom.example.com"]}
```

A client that does not know the field ignores it, as the terminal's
decoder already does. The list is shown only to principals the control
endpoint has authenticated.

### `loom --ui` against a remote daemon

```
loom --ui --addr wss://loom.example.com/v2/control --session <id> \
  --token-file <member-credential> [--open]
```

`loom` opens the control connection with the member's bearer, exactly as
the remote terminal launch does, and requires `wss` for any address that
is not loopback. It derives the page origin from the address
(`wss://<name>[:port]` becomes `https://<name>[:port]`), and refuses with
status 1, before minting, when the `hello` does not list that origin; the
message names `--ui-origin`. It never starts or stops a daemon on this
path. Otherwise it sends `ui.link` and prints, or opens, the origin joined
to the returned path, as the loopback path does. `ui.link` itself does
not change.

The owner's own machine keeps using the loopback link. Nothing here
changes how a loopback request is admitted.

## Threat model

**A network attacker** between a teammate's browser and the proxy sees
TLS. The cookie is `Secure`, so it never travels over `http`; HSTS keeps
the browser from trying `http` after the first visit; a page the attacker
injects over `http` before that presents `http://` in `Origin` and is
refused at the upgrade. The ticket crosses the network only inside TLS.
The hop from the proxy to the daemon is loopback on one host, and the
daemon cannot be bound anywhere else.

**Other tenants** come in three kinds. Sites on sibling subdomains share
the registrable domain, so `SameSite` does not separate them from the
page; the `__Host-` prefix stops them setting its cookie, the exchange
refuses `Sec-Fetch-Site: same-site`, and the upgrade's exact `Origin`
match refuses their scripts. Other accounts on the daemon's host can
reach the loopback listener with any `Host` they like, which was already
true under 051, and still need a ticket or a cookie. Other applications
behind a shared proxy are excluded by the dedicated-origin requirement,
because nothing but the daemon may serve script on that origin.

**A stolen cookie** is worth more than under 051, because it can be
presented from anywhere the proxy is reachable rather than only from the
daemon's host. Its reach is unchanged: observer access to one session,
for at most 8 hours, ending at the next check after the member's
credential is revoked or rotated or the membership is removed. Binding a
UI session to the client's address was rejected: the daemon would have
to trust a forwarded header, and addresses change under NAT and on
mobile networks.

**A hostile page on another origin** cannot read the cookie (`HttpOnly`),
cannot make the browser send it (`SameSite=Strict`), cannot open the
socket (exact `Origin`), cannot frame the page (`frame-ancestors 'none'`),
and cannot drive the exchange without a ticket, and is refused by
`Sec-Fetch-Site` if it has one. A DNS rebinding page presents its own
name as `Host`, which is neither loopback nor listed.

## Frozen-interface impact

This changes admission rules 051 fixed in Part 1.6, adds a daemon flag,
adds a field to the `hello`, and adds a launch to `loom`. 051's Open
section defers remote access to "the phase that needs it", and the change
carries its own threat model and its own costs, so it is a new proposal
rather than an addendum to 051. 052 is unused: `main` stops at 051, and
the open pull requests carry `033`, `045` and `050`.

## Impact

- `client/daemon/main`: parses and validates `--ui-origin`, and refuses
  it without `--ui`.
- `client/daemon/ui_http`: `loopback_host` becomes the resolution to a
  page origin; `origin_matches`, `session_cookie` and `set_cookie` take
  the page origin.
- `web_view/page`: `content_security_policy` takes the page origin, for
  the `ws`/`wss` scheme.
- `client/daemon/server`: the `hello` `origins` list.
- `packages/tui`: `loom --ui --addr … --token-file …`, the origin check
  against the `hello`, and the `Hello.view` decoder keeping the list.
- `docs/client-protocol.md` §2.4 and spec Part 1.6: the allowed-origin
  rule; `docs/architecture/multiplayer.md`: how a teammate opens a page.

## Verification required

- Admission, per page origin: a listed `Host` is admitted and an unlisted
  non-loopback one is refused with `403`; the upgrade refuses
  `http://<listed name>` and a mismatched port; the exchange refuses
  `Sec-Fetch-Site: same-site`.
- Cookies: a remote exchange sets `__Host-loom_ui` with `Secure` and
  `Path=/`, a loopback exchange sets 051's cookie unchanged, and a remote
  request presenting only `loom_ui` gets `401`.
- The policy names `wss://` for a remote origin and `ws://` for loopback.
- `--ui-origin` refuses `http://`, a path, a query, a loopback host, and
  use without `--ui`.
- A member mints a link over `wss` control through a real proxy, the page
  loads, and rotating the member's credential closes it.
- `loom --ui --addr` refuses an origin the `hello` does not list, without
  minting.
- A proxy that rewrites `Host` to the loopback address gets a page whose
  socket is refused, and the operator-facing documentation names the
  `Host`-preserving setting for the proxies it shows.

## Cost

- The proxy is trusted. It holds the TLS key, sees every ticket, cookie,
  bearer and transcript byte, and a misconfigured one (a rewritten
  `Host`, a stripped `Origin`, a logged query string) weakens the page in
  ways the daemon cannot detect. Most fail closed, though not all at the
  first check. A `Host` rewritten to an unlisted name is refused. One
  rewritten to the loopback address, which is nginx's default for
  `proxy_pass`, is admitted as `Loopback`: the exchange spends the ticket
  and sets 051's cookie, and the page then fails at the upgrade, whose
  `Origin` is the `https` origin rather than `http://127.0.0.1:<port>`. A
  logged ticket does not fail closed at all.
- The owner must dedicate a host name to the daemon.
- A stolen cookie works from anywhere the proxy is reachable, for the
  life of the UI session.
- Two cookie shapes and two `Origin` rules, selected by one value, where
  051 had one.
- A daemon behind a proxy runs on a fixed port.

## Decision

**Proposed.** Reach the web view from other machines through a
TLS-terminating reverse proxy on the daemon's host, forwarding to the
loopback listener, at a host name dedicated to the daemon. The owner
lists that origin with `--ui-origin`; the daemon admits a `Host` that is
loopback or listed, and derives the `Origin` rule, the cookie
(`__Host-loom_ui`, `Secure`) and the policy's socket scheme from which
one matched. A teammate mints their own ticket with `loom --ui --addr
wss://…` and the member credential `sessions.invite` gave them, so the
page carries their principal and ends with their credential. Terminating
TLS in `loomd` was rejected because it gives up the loopback-only bind
and adds certificate handling to the daemon; trusting forwarded headers
because the daemon cannot authenticate them; and owner-minted links
because they would let one principal's ticket act for another.

## Open

- **The ticket in the fragment.** Moving the ticket out of the query
  string removes the proxy-log requirement and the one failure in this
  design that is silent. It changes the exchange for loopback as well, so
  it is a decision about 051's route as much as this one.
- **A shorter remote lifetime.** A remote UI session could live less than
  8 hours, since its cookie is usable from more places. This design keeps
  one lifetime.
- **More than observer.** When a later phase lifts the observer cap, a
  remote page gains the member's full role, and the stolen-cookie cost
  above grows with it. That phase should revisit the lifetime and the
  fragment together.
