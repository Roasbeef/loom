# protocol-change/052: the web view behind a TLS origin

**Status**: PROPOSED 2026-09-26; ACCEPTED 2026-10-18, as built in the
addendum below, which differs on the configuration, the cookie names and
the launcher · **Affects**: Part 1.6 client
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

## Addendum: accepted, as built (2026-10-18)

The owner wants to open the web view of a daemon on a Linux machine from a
phone, through Tailscale Serve on that machine. Serve terminates TLS at
`https://<node>.<tailnet>.ts.net:<port>` and forwards to the daemon's loopback
listener, which is the same-host TLS proxy this proposal chose. This addendum
records what was built and where it differs from the proposal above.

### What did not change

The daemon still binds loopback only. `--bind` still refuses anything but
`127.0.0.1:<port>` and `[::1]:<port>`, and it already pins the port, so a
proxy has a stable target with `loomd --ui --bind 127.0.0.1:<port>`. No
configuration key for the port was added.

The daemon reads no `X-Forwarded-*` or `Forwarded` header, anywhere. A test
sends a foreign `Host` with `X-Forwarded-Host` and `Forwarded` naming the
listed origin and gets `403`.

Admission is the resolution the proposal gives. `ui_http.page_origin` turns
the request's `Host` into `Loopback(host)`, exactly as 051 admits it, or
`Remote(origin)`, when the `Host` names a listed origin, or refuses it with
`403`. The `Host` is compared lowercased and with an explicit `:443`
dropped, against the origin's host and port as a browser writes them, so
the listed name on another port, or with a trailing dot, is refused. Every
later rule is a function of that one value: the socket's `Origin` rule
(`ui_http.origin_matches`), the cookie names and attributes
(`ui_http.set_cookie`, `ui_http.set_login_cookie`, and the readers
`ui_http.session_cookies` and `ui_http.login_cookies`), the policy's socket
origin (`ui_http.socket_origin`, then `page.content_security_policy_for`),
and the address a page mints links under (`ui_http.address`, which is
`PageGrant.address`). This is why the allow-list replaces the loopback check
rather than weakening it: a DNS rebinding page still presents its own name,
which is neither loopback nor listed, and is refused at the same point and
with the same status as under 051.

The `Origin` rule, the `Sec-Fetch-Site` rules, the policy and the `hello`
field are as proposed.

### The configuration is a file key, not a flag

The proposal named `loomd --ui-origin`. The list is read instead from the
daemon's configuration file, once at startup:

```toml
[daemon]
ui = true
ui_origins = ["https://obelisk.tail0a99b.ts.net:8443"]
```

A proxy's origin is part of a deployment that outlives one command line (a
Serve configuration survives a reboot), and `[daemon]` already holds `ui`,
the file form of `--ui`. One place to read keeps the rules in one parser
(`client/daemon/ui_origin`), which the catalogue's `[daemon]` validation
(`limits.from_fields`) calls too, so a session's configuration file and the
daemon's startup refuse the same bad entry with the same words. No flag was
added. The key is named for the view, beside `ui`, rather than
`allowed_origins`, because nothing else in `[daemon]` is admitted by it: the
`/v2` endpoints take bearers and never read the list.

Each entry is parsed whole, and a bad one refuses the daemon's start with an
error that quotes it. An entry is `https://`, a host, and an optional port,
with nothing else: no user information, path, query or fragment, and no
percent-encoding. A single trailing `/` is accepted and dropped. The host is
a DNS name, an IPv4 literal or a bracketed IPv6 literal. The scheme and host
are lowercased and the port is dropped when it is 443, which is the form a
browser writes in `Origin` and `Host`. At most sixteen entries are read, and
a repeated one is kept once.

`http` is refused for every host, including loopback ones, for three
reasons. The cookies on a listed origin are `Secure`, which a browser will
not send over `http`. An `http` origin on another machine would carry
tickets and cookies across the network in clear text, which is what the
proxy exists to prevent. And the loopback names are already admitted
without a list, so an `http://127.0.0.1` entry could add nothing. A listed
loopback host (`localhost`, `127.0.0.1`, `[::1]`) is refused for the last
reason, as a likely mistake.

A list on a daemon that does not serve the view refuses startup, as the
proposal's flag did without `--ui`. The type keeps the rule after startup:
the list is a field of `main.ViewOn`, so a daemon without the view has no
list to consult.

### The cookies are `__Secure-` and keep their keyed paths

The proposal chose `__Host-loom_ui` with `Path=/`. It was written before the
page keys (051, the operator addendum) and the browser login (065) gave each
cookie a path of its own: a page's cookie is scoped to `/ui/p/<page key>`
and a login's to `/ui/l/<login key>`. A remote origin keeps those paths, and
its cookies are `__Secure-loom_ui` and `__Secure-loom_login`, each with
`Secure` added to the loopback attributes:

| | `Loopback(host)` | `Remote(origin)` |
|---|---|---|
| Page cookie | `loom_ui=…; HttpOnly; SameSite=Strict; Path=/ui/p/<key>` | `__Secure-loom_ui=…; HttpOnly; SameSite=Strict; Path=/ui/p/<key>; Secure` |
| Login cookie | `loom_login=…; HttpOnly; SameSite=Strict; Path=/ui/l/<key>; Max-Age=…` | `__Secure-loom_login=…; HttpOnly; SameSite=Strict; Path=/ui/l/<key>; Max-Age=…; Secure` |

`__Host-` requires `Path=/`, and `Path=/` would cost two things the keyed
path provides:

- **Other ports of the same name.** Browsers do not scope a cookie by port.
  A Tailscale node name commonly serves other things through Serve on other
  ports, and a cookie at `/` would be sent to every one of them. The keyed
  path is what keeps the page's cookie off every path that does not name its
  key, and so off every other service on that name.
- **Several pages in one browser.** One cookie name at `/` holds one value,
  so a second page would overwrite the first page's cookie. 051's addendum
  on several pages per principal and session relies on each page's cookie
  living under its own path.

What `__Host-` adds over `__Secure-` is that a sibling subdomain cannot set
the cookie. The keyed design already holds against what such a cookie could
do. A request is read only by the name its origin implies, and every value
it carries under that name is tried, up to four, so a planted value that
sorts first cannot shadow the real one. A value is accepted only when its UI
session is live under the key in the path, so a planted value is passed over
unless it is the planter's own page, and that page lives under the planter's
key, at a path the victim's browser has no reason to visit. Steering the
victim there takes a navigation from the sibling, which is `Sec-Fetch-Site:
same-site` and refused. A login cookie must verify under the daemon's root
key, carry the key in its path, and match the nonce the victim's own page
keeps in `localStorage`, and its resume is a `POST` that must be
`same-origin`. The residue is a denial of the page: a sibling that knows the
page key can plant four values under longer paths and push the real cookie
past the bound. It gains no access.

Two assumptions sit under that argument. Which sites count as siblings
depends on the Public Suffix List: if `ts.net` is listed, the siblings of a
Serve origin are the other nodes of the same tailnet, and if it is not, every
`*.ts.net` name is same-site. The defence above does not depend on which.
And neither prefix isolates another service on the same host name and a
different port, because browsers do not scope cookies by port. Such a service
that learns a page key can overwrite that page's cookie, or have the browser
send the cookie to its own port at `/ui/p/<key>` and so read it. Against a
service on the same name, the secrecy of the page key is the whole defence,
as it is for another loopback port under 051. The owner should run on that
name only services they trust.

A remote request that presents only `loom_ui` gets `401`, and a loopback
request that presents only `__Secure-loom_ui` gets `401`.

### Links on a listed origin, and a device link

`ui.link` is unchanged for a page link: the reply is a path, and the client
joins it to the origin it chooses. `loom ui --origin <origin>` builds the
link on a listed origin instead of the loopback listener. The origin must be
one the `hello` lists, compared after the daemon's normalization, or the
command refuses before anything is minted.

`ui.link` gains one optional field, `device`. With `"device": true` the
request asks for a link that signs another device in to the principal's
home: the home's ticket, `Remembered`, `Fresh`, at the asked ceiling, and
redeemable for the device link's ten minutes (`ui_sessions.device_ms`)
rather than sixty seconds, so a person can carry it to a phone. The reply is
the ordinary `ui.link` reply, whose `expires_in_ms` says which lifetime the
ticket got. A device link names no session and cannot decline the login: a
request with `session_id`, or with `"remember": false`, is refused with
`bad_request`. It carries no page deadline and no parent login, since no page
made it, so the login its exchange sets has thirty days of its own, as a
`loom ui` home link's does. It is not counted against the grant allowance a
page's own device link spends: that allowance keeps a stolen page from
minting credentials, and the credential that asks here can already mint a
home link at will. A daemon that predates the field ignores it and mints a
sixty-second home link, which the reply's `expires_in_ms` shows.

`loom ui --device [--origin <origin>]` sends that request. It builds the link
on the only listed origin, or the one `--origin` names when several are
listed, and refuses with a message naming `ui_origins` and `[daemon]` when
none is. It prints the link on standard output, as `loom ui` does, and a QR
code of it on standard error with how long it lasts, so a phone can scan it
and a script still reads one line. The code is drawn black on white with
explicit ANSI colours, in Unicode half blocks, by `qrkit` 0.6.0, a pure Gleam
encoder whose only dependency is `gleam_stdlib`; Loom draws the code and does
not encode it.

The page's own device link (065) now uses the page's origin as well, because
`PageGrant.address` is `ui_http.address(origin)`. "Sign in another device"
on a page opened through the proxy mints a link on the proxy's origin.

### What was not built

- **`loom --ui --addr wss://…` for a teammate.** The `hello` field it needs
  is built and the terminal's decoder keeps it (`WebViewAt.origins`); the
  launch against a remote daemon is not. The owner's case, a second device of
  their own, is `loom ui --device` on the daemon's machine.
- **The ticket in the fragment** stays Open, as above. Another proxy than
  Serve must still be configured not to log the `ticket` parameter.
- **HSTS.** Tailscale Serve sends no `Strict-Transport-Security` header that
  the operator chooses. The page's `http` variant is refused at the socket
  upgrade by the exact `Origin` rule, and the cookies are `Secure`, so a page
  injected over `http` before a first visit gets neither the cookie nor the
  socket. The daemon does not send the header itself, because it cannot know
  whether the request reached the proxy over TLS.
- **The claim command on a remote page.** A page draws `loom claim --addr
  ws://…` only for a loopback `Host` (`ui_socket.claim_address`). A page on a
  listed origin draws none, since the daemon cannot name a control address
  for another machine.

### Verification as built

`client/ui_origin_test` covers the entry grammar (good and bad entries, the
normalization, a fixed-seed port property), the `Host` matrix (loopback, the
listed origin in any case, the listed name on another port, a foreign name,
forwarded headers ignored), the socket's `Origin` rule, the cookie names and
attributes per origin, and the policy's scheme. `client/daemon_limits_test`
covers the startup refusals. `client/ui_route_test` drives a real listener:
the `Host` matrix over HTTP, a remote exchange that sets `__Secure-loom_ui`
with `Secure` and a `wss://` policy, a page that reads only its origin's
cookie name, a socket that refuses `http://` and the wrong port and admits
the listed origin, the `hello`'s `origins`, and a device link that lives ten
minutes and sets `__Secure-loom_login`. `tui/view_device_test` covers the
launcher's words, the choice of listed origin, the wire, and a QR code that
decodes back to its link. A real drive through Tailscale Serve from a phone
has not been run.

## Addendum: a device link scanned from a QR code (2026-10-19)

The admission table above keeps "Exchange `Sec-Fetch-Site`: `none` or
`same-origin`" for both origins, and that is still the rule for redeeming a
ticket on a `GET`. A phone's camera opens the device link's QR code
`cross-site` or with no header, so as built it was refused with `forbidden
exchange`, which is how the owner found it. Protocol-change/051's addendum of
the same date answers such a `GET` with a confirmation instead of a `403`:
one button that posts the ticket to the exchange's path, accepted only as a
`same-origin` form post. Nothing in this proposal's origin rules changes. The
post is admitted under the same `PageOrigin` as the `GET`, so the press on a
listed origin sets `__Secure-loom_ui` and `__Secure-loom_login` with `Secure`,
and the confirmation names the listed origin it signs in to. A sibling
subdomain, `same-site`, can show the confirmation and cannot post it.

## Addendum: `.localhost` names and a page at `/` (2026-10-21)

This addendum changes two things the proposal froze: the set of `Host` values
admitted as `Loopback`, and the set of routes. It is made for issues #1051
and #1052. The origin rules, cookies, tickets and policy are unchanged.

### Problem

The loopback host rule admits `127.0.0.1`, `[::1]` and `localhost` and nothing
else. An owner who pins `[daemon] bind` to a fixed port wants a stable name
that says what it is, such as `http://loom.localhost:7440`, and there is none
the daemon will admit. Separately, `GET /` answers `unknown endpoint`. Every
web view page needs a credential, so the daemon's bare address, which includes
the fixed bind port and a listed origin's hostname, never reaches the view.

### `.localhost` names are loopback

`ui_http.loopback_host` also admits a `Host` of one or more DNS labels
followed by `.localhost`, with any port, compared lowercased. The admitted
request is `Loopback(host)` with `host` as the header was sent, so every rule
that follows from `Loopback` applies unchanged: the cookie names, the lack of
`Secure`, the `ws://` policy, and a socket `Origin` of `http://` and the
`Host`. The socket accepts `http://loom.localhost:7440` for a page served at
that `Host`, and not the same name on another port, another name, or `https`.

A label is one to 63 characters from `a-z`, `0-9` and `-`, with no hyphen at
either end (RFC 1123). The whole name is at most 253 characters. These are
refused:

- `localhost.evil.com`, because the name must end in `.localhost`, not contain
  it.
- `evil.com.localhost.`, because a trailing dot leaves a name that does not
  end in `.localhost`.
- `.localhost`, `a..localhost` and `.a.localhost`, because a label is empty.
- Any label with an underscore, a space, `@`, a non-ASCII character or a
  leading or trailing hyphen.
- Anything with a bad port, as for the existing names.

`evil.example.localhost` is admitted. That is intended: the rule is the
suffix, not who chose the labels.

The DNS rebinding argument is the one that protects the existing names. 051
and this proposal refuse a `Host` the attacker's page can reach the daemon
under, because rebinding makes the browser send the attacker's own name to a
loopback address. RFC 6761 section 6.3 has a resolver treat every name under
`.localhost` as loopback and not consult DNS, and Chrome and Firefox do so,
so no DNS answer an attacker controls can point such a name at a remote
host. A page cannot rebind one of these names the way it rebinds its own.
Safari and some other resolvers do not pin the suffix. There the name reaches
this daemon only if the operator adds an `/etc/hosts` line, which is the
operator's choice. A resolver that sent the name to DNS would let an attacker
answer it with a loopback address, which any page can already do to
`localhost`, and not with a remote one that the daemon would then see.

`ui_origins` refuses an entry that names a `.localhost` host, as it refuses
`localhost`: the loopback check comes first, so a listed name would never be
reached.

### A page at `/`

`GET /` is a route. It serves a fixed document that carries no credential and
has no side effect, and a script, `/ui/assets/web_view_root.js`, listed with
the other assets. It is the only route outside `/ui`. A method other than
`GET` is `404`, as is every other path outside `/ui` and `/v2`.

It is admitted by `page_origin` as every `/ui` request is: a loopback `Host`,
including a `.localhost` name, or a listed origin, and `403 forbidden host`
otherwise. It is secured by `ui_http.secured`, so it carries the same content
security policy, with no inline script, and sets no cookie. With the view off
it is `404`, as `/ui` is. It does not require `Sec-Fetch-Site`: there is no
credential for another site to use and no state to change.

The script looks in this origin's `localStorage` for the entries
`web_view_enter.js` writes: an item named `loom.login.` and a 32-digit key
whose value is a 64-digit nonce (065). `localStorage` is scoped to scheme,
host and port, so every entry belongs to the origin that served the page. If
exactly one entry matches both shapes, the script replaces the location with
`/ui/l/<key>/home`, the login's resume page. If several match, it lists them
as links to their resume pages in key order and navigates to none, because the
page cannot tell which the daemon still honours and a person can. If none
matches, or `localStorage` cannot be read, the document says to run `loom ui`,
and `loom ui --device` on a listed origin. Every storage access is inside
`try`.

The page adds no authority. It holds no key and no nonce: the nonce stays in
`localStorage` and is read only by script on the same origin, as the resume
page already reads it. The page carries no cookie and sets none. What it
navigates to is the resume page, which posts the nonce and is verified by the
daemon under the login cookie, as when the person opens the bookmark. A
request that reaches `/` from another site cannot read the storage, and
cannot make the page do anything but show its fixed words or move the tab to a
page the browser could be sent to by any link.

### Cost

One route and one asset are added to a frozen set, and the host rule admits a
class of names instead of three. Both rest on the browser's own resolution of
`.localhost`, which this daemon cannot check. The root page is a convenience
and nothing depends on it; removing it restores `unknown endpoint`.

### Verification

`client/ui_http_test` checks the label grammar with a fixed-seed property over
generated names, the accepted and refused shapes above, the socket `Origin`
rule for a `.localhost` page, and the route. `client/ui_origin_test` checks
that a listed `.localhost` entry is refused. `client/ui_route_test` drives a
real listener: `/` on loopback, on a `.localhost` name and on a listed
origin, the `403` for other hosts, `404` for a `POST`, no `Set-Cookie`, the
policy, and the script served byte for byte. `web_view/page_test` checks the
document. The script's navigation has not been run in a browser by a test.
