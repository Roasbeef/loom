# protocol-change/065: a home page, a browser login, a browser claim, session creation and an admin page on the web view

**Status**: DRAFT 2026-10-03, amended the same day for the owner's rulings
(a thirty-day browser login that is itself a macaroon-style credential; a
browser claimant is never shown a key; creation only in a known workspace;
operator-ceiling pages open saved sessions); nothing implemented · **Affects**:
Part 1.6 client protocol (`ui.link`, `credentials.claim`, `principals.list`,
four new control commands, new `/ui` routes), the `loom ui`, `loom claim`
and `loom access` command lines, the catalogue schema (version 5), and four
owner rulings recorded in `docs/next.md` · **Raised by**: the owner's
request of 2026-10-03 for a web mode that makes sessions, switches between
them, administers access and lets an invitee choose their name · **Builds
on**: [051](051-web-view-route.md) (the page, its three secrets, switching,
the invite control), [053](053-owner-admin-and-claims.md) (claims, `loom
access`, the admin page designed in phase 4),
[054](054-roster-push-on-subscribe.md) (the roster a page draws names from)
· **Design note**:
[docs/design-notes/web-workspace-mode.md](../docs/design-notes/web-workspace-mode.md)
has the reasoning and the pull-request plan; this document is the rule.

## Problem

A browser reaches the web view through one route family, and every page
on it is bound to one session. `ui.link` requires a `session_id`
(`client/daemon/protocol.gleam:428`), the ticket's grant names one session
(`ui_sessions.gleam:127`), the cookie's path is the page key's, and every
request re-checks membership in that session (`client/daemon/server.gleam:356`).
An operator page can list the principal's sessions and switch to a running
one (051, the addendum on switching sessions), and an owner's operator page
can invite into its own session (051, the addendum on inviting from the
session page). That is the whole of what a browser can do without a
terminal, and a browser keeps nothing that outlives eight hours.

The owner asked for four things a browser cannot do today:

1. A page that is not a session's: a front door that lists the sessions
   the person holds and opens any of them, including a saved one, and that
   a bookmark reaches tomorrow without `loom`.
2. Creating a session from the browser.
3. An admin page: who has access to which session, in which role; invite,
   change a role, revoke, rotate; the invitations not yet redeemed.
4. The invitee choosing the name they are shown under, in the browser, and
   getting in with a cookie that is their credential rather than a key to
   keep.

Four rulings stand in the way, each made for a reason this proposal must
keep or argue against: daemon control stays in the terminal (2026-09-27);
operator surfaces do not open saved sessions; the observer page lists
nothing; and 053's admin page waits for use of the terminal overlay
(2026-09-30). And one gap is structural: a person with no `loom` on their
machine has no way to obtain a credential (`loom claim`) or a ticket (`loom
ui`), so "invite people" to a web UI implies the browser can do both.

## What was considered

### How a browser stays signed in

- **A bearer credential of the existing kind, kept by the browser.** What
  ADR-014 and 051 refused: a credential in browser storage.
- **A random cookie backed by a daemon table**, like 051's UI session but
  thirty days long. It works, and it costs a durable table row per login
  that must be swept, and it is a second credential kind in all but name,
  which 051, 052 and 053 each declined.
- **A macaroon-style token as the cookie, chosen (the owner's
  suggestion).** The daemon mints it from a root key and verifies it from
  that key and the token's own caveats; the catalogue holds one credential
  row per login for revocation, keyed like every credential; the token is
  stored nowhere. It fits the existing hashed-credential model because the
  row's digest is the digest of the token's identifier, so every check that
  takes a digest runs unchanged. It can be narrowed later by appending a
  caveat, without the daemon.
- **A key shown once and a sign-in form** (the first draft). Withdrawn by
  the owner's ruling: nobody is handed a key.

### Rotating the login on use

- **Rotate on every visit, detect reuse.** Needs a stored current
  identifier per login, so the daemon stores more than a row and the root
  key; two tabs that visit at once race and one is signed out; a thief who
  visits first signs the owner out. Rejected.
- **Fixed thirty-day expiry, listing and last-seen, chosen.** The owner
  sees every login, when it was issued and last used, and revokes one or
  all; a used login does not renew itself.

### Where a browser-created session may point

- **A path field for the owner.** A stolen owner page could create a
  session in any directory the daemon can read and prompt it, where today
  it reaches only sessions that exist. Rejected; confirmed by the owner.
- **A workspace chosen from the ones the owner's listing already shows,
  chosen.** The browser names an index into a list the daemon drew; the
  daemon resolves the path. A new workspace is created from a terminal
  once.

### The admin page's powers

- **053 phase 4 as designed**: reduce-only, grants rendered as `loom
  access` lines. The owner asked to invite from the page, and the session
  page already does, so a reduce-only admin page would be less than the
  session page.
- **Full powers, unbounded.** A stolen page could fill the catalogue with
  members. Rejected.
- **Full powers, with the session page's allowance, chosen.** Every grant
  from a page (invite, rotate, a promotion to operator, a device link)
  counts against the one allowance 051 keeps for the credential, three an
  hour. Reductions are free. The page lives fifteen minutes, is minted only
  from an owner's operator home, and is loopback-only, as 053 said.

### How a name reaches the principal

- **A new `principals.rename` only**, with the invitee renaming after the
  claim. It works, and the roster shows the inviter's name until they do.
- **A `name` on the claim, chosen**, applied in the transaction that binds
  the credential, so the first attach already carries it. `principals.rename`
  is offered as an optional later command.
- **Unique names.** Rejected: the ID is the identity, a clash would fail a
  claim on a name the invitee cannot see is taken, and it would mean
  nothing for authority.

### How a browser claims

- **No browser claim; invitees need `loom`.** Fails the request for anyone
  without a terminal.
- **Option C in the browser**, the browser drawing the credential and
  keeping it in storage. Rejected, as above.
- **The claim binds a login, chosen.** The daemon draws the login's
  identifier, binds its digest as the principal's credential with
  `storage/access.claim` as any claim is bound, sets the cookie, and the
  person is in. There is no reply to lose: the credential is the cookie
  the response set, and a lost response leaves an open claim the person
  presents again.

### Opening a saved session from a page

- **Keep the ruling**: saved sessions are text, resume from a terminal.
  Fails "switch between them" for anything not already running.
- **Let a page run the control command's own path, chosen and confirmed
  by the owner**: the same authority check (`client/daemon/server.gleam:1630`),
  the same registry turn (`client/daemon/manager.gleam:991`), with the epoch
  the page was admitted in, bounded by a wait, and only for an
  operator-ceiling page whose principal holds Operator or Owner on the
  target. The listing is still not permission; the membership is.

## Proposal

### The grant

`ui_sessions.Grant` becomes:

```
Grant(scope: Scope, credential: Digest, principal: String,
      ceiling: Role, reach: Reach, remember: Remember)

Scope    = Session(id: String) | Home | Admin
Reach    = OneSession | Workspace
Remember = Remembered | Forgotten
```

- `Session(id)` is today's grant in every check. `Home` is the principal's
  home page. `Admin` is the owner's admin page.
- A `Home` or `Session` grant lives `session_ms` (eight hours) from its
  exchange, or the minting page's deadline if earlier (`mint_before`,
  unchanged). An `Admin` grant lives `admin_ms`, 900,000 (fifteen minutes),
  or the minting page's deadline if earlier. A ticket lives `ticket_ms`
  (sixty seconds), except a device link (below), which lives `device_ms`,
  600,000.
- `max_pages` (four) bounds a principal's live pages per `Session(id)`, as
  today, and separately per `Home` and per `Admin`.
- `reach` is `OneSession` for a ticket `ui.link` mints with a `session_id`,
  and `Workspace` for a `Home` ticket and for every ticket a `Home` or
  `Workspace` page mints. A page's reach decides whether it draws a "Home"
  control; nothing else reads it. An `OneSession` page is exactly today's
  page, observer rulings included.
- `remember` is `Remembered` only on a `Home` ticket minted by `ui.link`
  without `--no-remember`, by a device link, or by the claim. A remembered
  exchange sets the login (below) as well as the page. A ticket a page
  mints for a switch or for the way home is `Forgotten`.
- A ticket is redeemed only at the exchange of its scope: a `Session(id)`
  ticket at `/ui/sessions/<id>`, a `Home` ticket at `/ui/home`, an `Admin`
  ticket at `/ui/admin`. Presented elsewhere it is spent and refused, as a
  ticket presented against another session is today (`OtherSession`).

### The browser login

A login is a credential the daemon mints and verifies from a root key, in
the first-party macaroon construction: an identifier, a list of caveats,
and an HMAC-SHA256 chain over them. The browser carries it as a cookie.

**Token.** ASCII, at most 512 bytes:

```
loomb1:<id>:<caveat>|<caveat>|...|<caveat>:<sig>

id      = 32 lowercase hex digits (16 random bytes)
caveat  = <name>=<value>; name is one lowercase letter;
          value is 1..128 bytes of [A-Za-z0-9._-]
sig     = 64 lowercase hex digits
sig0    = HMAC-SHA256(key: root, data: "loomb1:" <> id)
sigN    = HMAC-SHA256(key: sigN-1, data: caveatN)
```

`:` and `|` are legal cookie-value bytes and outside the value alphabet,
which is the alphabet of a principal ID (`storage/access.gleam:1074`), so
the token parses without escaping. `gleam_crypto` 1.6.0, already a
dependency of `host`, provides `hmac` and `secure_compare`; no new
dependency and no new FFI.

**Root key.** 32 bytes from `crypto.strong_random_bytes`, written once to
`<state-dir>/browser.key` at mode `0600` with `atomic_write_private`
(`host/bootstrap.gleam:403`), read at start, regenerated if absent. It never
enters a token, a log or a reply. Deleting it and restarting ends every
login.

**Caveats at minting**, all six, in this order; the daemon refuses a token
missing any of them:

| Caveat | Value | Enforced as |
|---|---|---|
| `p` | the principal ID | must equal the credential row's principal |
| `c` | `observer` or `operator` | the ceiling of every ticket the login mints |
| `r` | `workspace` | the reach of every ticket the login mints |
| `e` | unix milliseconds | the login is refused at and after this instant; set to minting plus 2,592,000,000 and never extended |
| `k` | 32 hex digits | the login key: the cookie's path and the route's `<key>` must match |
| `n` | 64 hex digits | the SHA-256 of the login nonce the browser posts |

**Intersection.** A name may repeat, and a repeat narrows: `c` takes the
smallest ceiling, `e` the earliest instant, a future `s` (a session ID)
restricts every ticket the login mints to that session and two different
`s` values allow nothing, and `p`, `r`, `k` and `n` may not repeat with
another value. A name the daemon does not know refuses the token. Nothing
in this change appends a caveat; the rules are what let a later holder
narrow a token without the daemon and never widen one.

**Storage.** One row in `access_credentials` per login: `digest =
SHA-256(id bytes)` as 64 hex, the principal, `state`, and three columns
added at catalogue version 5:

```sql
ALTER TABLE access_credentials ADD COLUMN kind TEXT NOT NULL DEFAULT 'bearer'
  CHECK(kind IN ('bearer', 'browser'));
ALTER TABLE access_credentials ADD COLUMN issued_at_ms INTEGER;
ALTER TABLE access_credentials ADD COLUMN last_seen_ms INTEGER;
```

The forward migration at `user_version` (`storage/catalogue.gleam:150`)
moves 4 to 5; an older daemon refuses a version 5 catalogue, as 053 says
of version 4. Every existing row is `bearer`. Keying the row by the digest
of the identifier is what lets every existing check run unchanged: a page
minted from a login carries `SHA-256(id)` as `Grant.credential`, and
`manager.authenticate`, `session_authority`, `frame_authority` and
`administer` take it as they take a bearer's digest. A login presented as
a bearer on `/v2/control` is `401`, because the daemon hashes the whole
token and finds no row; `loom --token` and `--token-file` refuse a value
beginning `loomb1:` as they refuse `loomclaim_`. `revoke_member` and
`rotate_member` revoke `browser` rows as they revoke `bearer` rows.
`storage/access.claim` takes a `kind`, so a browser claim binds a `browser`
row under 053's rules 1 to 5 unchanged.

**Cookie.** On a loopback page origin:

```
loom_login=<token>; HttpOnly; SameSite=Strict; Path=/ui/l/<key>; Max-Age=2592000
```

Under 052's `Remote(origin)`:

```
__Host-loom_login=<token>; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000
```

The page cookie is unchanged and keeps no `Max-Age`.

**Login nonce.** 32 random bytes, hex, delivered once in the body of the
response that sets the login cookie (a remembered exchange, or the claim),
as a `data-login-nonce` attribute beside the page nonce. The enter script
keeps it in `localStorage` under `loom.login.<key>` and the page nonce in
`sessionStorage` as today. The daemon keeps its digest as caveat `n` and
nothing else.

**Verification**, at `POST /ui/l/<key>/home`, in this order, each refusal
`401` with a fixed document and no echo: the cookie named for the page
origin parses as the shape above; the chain recomputes from the root key
and `secure_compare` matches `sig`; every caveat holds (`k` equals the
path's key, `n` equals the SHA-256 of the body's `nonce`, `e` is after
now, no unknown name, no widening repeat); the row for `SHA-256(id)` is
found, `active` and `browser`, and its principal is `p`. The catalogue is
not consulted before the chain verifies. The daemon then mints and redeems
a `Home` grant (`credential: SHA-256(id)`, `ceiling` from `c`, `reach:
Workspace`, `remember: Forgotten`) and answers the enter page. It writes
`last_seen_ms` when the row's value is older than an hour.

**Device link.** A `Home` ticket with `remember: Remembered` and the
lifetime `device_ms`, minted by `ui_socket.device_link_for` for any home
page's own principal and ceiling, counted against the credential's grant
allowance (`reserve_invite`, three an hour), and shown once as an absolute
exchange address in a copy box. Its exchange sets a login on the device
that opens it.

**Logging.** No token, root key, nonce or login key is ever logged. The
daemon logs `daemon.login_issued` and `daemon.login_revoked` with the
principal ID and the credential's fingerprint.

### Routes

All under 051's prefix, host-checked first, with 051's headers and policy.
`<key>` and the page cookie are 051's; the page cookie's path is
`/ui/p/<key>`.

| Method and path | Checks, in order | Answer |
|---|---|---|
| `GET /ui/home?ticket=<t>` | loopback host; `Sec-Fetch-Site` `none` or `same-origin`; redeem a `Home` ticket | the enter page; the page cookie; the page nonce in the body; for a `Remembered` ticket also the login cookie and the login nonce |
| `GET /ui/p/<key>/home` | host; `Sec-Fetch-Site`; page cookie under the key names a live `Home` page; credential authenticates | the shell |
| `GET /ui/p/<key>/home/ws?csrf-token=<n>` | host; `Origin` is `http://` and the `Host`; page nonce; page cookie; credential | the home socket |
| `GET /ui/l/<key>/home` | host; `Sec-Fetch-Site` `none` or `same-origin`; `<key>` is 32 hex | the fixed resume page, whose script posts the login nonce from `localStorage` to the same path |
| `POST /ui/l/<key>/home` | host; `Sec-Fetch-Site` `same-origin`; body at most 1,024 bytes, `application/x-www-form-urlencoded`; the login verifies | the enter page for a new `Home` grant |
| `GET /ui/admin?ticket=<t>` | as the home exchange, for an `Admin` ticket | the enter page |
| `GET /ui/p/<key>/admin` | as the home page, for an `Admin` page, and the credential is the owner's | the shell |
| `GET /ui/p/<key>/admin/ws?csrf-token=<n>` | as the home socket, and the owner | the admin socket |
| `GET /ui/claim` | host; `Sec-Fetch-Site` `none` or `same-origin` | a fixed document with the two fields |
| `POST /ui/claim` | host; `Sec-Fetch-Site` `none` or `same-origin`; body at most 1,024 bytes; `token` is `loomclaim_` and 64 hex; `name` empty or valid; the claim redeems | the enter page for a new `Home` grant, with the login cookie and nonce |

The page and socket of a `Session` grant are unchanged. A `Home` and an
`Admin` grant have no session, so their `page_grant` checks the page
cookie, the key and the credential, and the admin's additionally that the
principal's kind is `OwnerPrincipal`; the membership check is skipped.

`POST /ui/l/<key>/home` and `POST /ui/claim` take a control-class parser
permit and are refused `503` when the daemon is not `Serving`. Each
refusal is a fixed document with no echo of the request. A claim token and
a login are never in a URL, a log line or a page document; the claim is
hashed and dropped.

### `ui.link`

```
c→s: {v:2, id, cmd:"ui.link",
      body:{session_id?, page:"observer"|"operator", remember?:true|false}}
s→c: {v:2, reply_to, event:"ui.link",
      body:{path:"/ui/sessions/<id>?ticket=<t>" | "/ui/home?ticket=<t>",
            expires_in_ms:60000}}
```

Without `session_id` the daemon mints a `Home` ticket for the caller's
principal and the requested ceiling; no membership is checked, since the
home lists what the credential may see. `remember` defaults to `true` for
a home ticket and is `bad_request` with a `session_id`. `loom ui
[--observe] [--no-remember] [--open]` with no `--session` sends it; the
home's default ceiling is `operator` unless `--observe`, and `loom ui
--session ID` keeps `observer` unless `--operate`.

### What a page may ask the daemon, by scope and role

Each is a function on `ui_socket` in the shape of `ticket_for` and
`invite_for`: every step is made afresh from the grant and the principal
the router authenticated, never from the page, and a page that has ended
asks nothing.

| Ask | Who | What the daemon does |
|---|---|---|
| `sessions()` | `Home`, any ceiling; `Session` operator page | `manager.authorized_page` with the page's digest; an observer `OneSession` page is given an empty list, as today |
| `open(id)` | operator-ceiling `Home` or `Session` page | `ticket_for` as today: membership, resident, mint with the page's ceiling and deadline, reach `Workspace`, `Forgotten` |
| `resume(id)` | operator-ceiling `Home` or `Session` page | `session_authority` must be Owner or `Participant(Operator)`; `manager.open(id)`; poll `manager.get` with `weft/poll` for at most `resume_wait_ms` (30,000) in a managed task; then as `open(id)`; the answer is dispatched as `Linked` |
| `home()` | any `Workspace` page | mint a `Home` ticket with the page's principal, ceiling and deadline, `Forgotten` |
| `signins()` | `Home`, any ceiling | the principal's own `credentials.signins` |
| `revoke_login(fp)`, `revoke_logins()` | `Home`, any ceiling | `credentials.revoke_login` for the principal's own; all of them |
| `device_link()` | `Home`, any ceiling | `reserve_invite`; mint a `Remembered` `Home` ticket living `device_ms` with the page's principal and ceiling |
| `create(index, name, scope)` | `Owning` `Home` page | resolve `index` against the listing this socket last drew; `name` as `valid_name`; `scope` `workspace_private` or `session_only`; key `page-<serial>-<n>`; `manager.create_scoped` with configuration `""`; then `resume(id)`; counted by `reserve_creation` (ten an hour per credential) |
| `admin()` | `Owning` `Home` page | mint an `Admin` ticket with the page's principal and deadline |
| `principals()`, `memberships(p)`, `members(s)`, `signins(p)` | `Admin` page | the owner-only reads with the page's digest |
| `invite(s, role, name)` | `Admin` page | `reserve_invite`; `manager.administer(Invite)` as `invite_for` does, into session `s` with `name`, claim `claim_ttl_ms` (one hour); release on a refusal that made nothing |
| `set_role(s, p, role)` | `Admin` page | `reserve_invite` when `role` is operator and the current role is observer; `administer(SetRole)` |
| `revoke(s, p)`, `revoke_credentials(p)`, `revoke_login(p, fp)` | `Admin` page | `administer(RevokeMembership)`, `administer(RevokeMember)`, `administer(RevokeLogin)`; no allowance |
| `rotate(p)` | `Admin` page | `reserve_invite`; `administer(Rotate)` with a claim of one hour; every login of `p` is revoked by the rotation |

An observer-ceiling page's socket admits only what today's observer socket
admits plus a click at the home control's fixed path; the home component's
observer variant has no message for `resume`, `create` or `admin`; and the
daemon refuses each from the grant it holds. Three layers, each enough, as
051 keeps for switching.

### `credentials.claim`

```
c→s: {v:2, id:1, cmd:"credentials.claim",
      body:{credential_digest:"<64 hex>", name?:"<display name>"}}
s→c: unchanged
```

`name`, when present, must pass the catalogue's display-name rule
(nonblank, at most 256 bytes, no control characters,
`storage/access.gleam:1088`), else `bad_request` and the claim binds
nothing and stays open. When it passes, `storage/access.claim` sets the
principal's `display_name` in the transaction that binds the credential.
`loom claim --name NAME` sends it. The browser claim (`POST /ui/claim`)
binds a `browser` credential through the same function with the form's
`name`, or none when it is empty, and never passes through `/v2/claim`.

### `sessions.members`

Owner-only, a `ControlRead`, refused `forbidden` for a member before any
parameter is judged, bounded as `principals.memberships` is.

```
c→s: {v:2, id, cmd:"sessions.members", body:{session_id, after?:<principal_id>}}
s→c: {v:2, reply_to, event:"sessions.members",
      body:{session_id, members:[{principal_id, name, role:"observer"|"operator"}],
            next?:<principal_id>}}
```

`loom access members SESSION [--after PRINCIPAL]` prints it, one JSON line
per member. The SQL is one new query over `access_memberships` joined to
`access_principals`, regenerated with `make gen-sql`.

### `credentials.signins` and `credentials.revoke_login`

```
c→s: {v:2, id, cmd:"credentials.signins", body:{principal_id?, after?:<fingerprint>}}
s→c: {v:2, reply_to, event:"credentials.signins",
      body:{principal_id,
            signins:[{fingerprint:"<16 hex>", issued_at_ms, last_seen_ms?}],
            next?:<fingerprint>}}

c→s: {v:2, id, cmd:"credentials.revoke_login",
      body:{principal_id?, fingerprint:"<16 hex>", epoch}}
s→c: {v:2, reply_to, event:"credentials.revoke_login", body:{principal_id, fingerprint}}
```

A member omits `principal_id` and reads or revokes its own; a member
naming another principal is `forbidden`. The owner may name any principal,
itself included. `fingerprint` is the first sixteen hex digits of the row's
digest, as `principals.list` already reports for a bearer; it identifies a
login and authenticates nothing. A revoked login refuses its next
`POST /ui/l/<key>/home` and ends every page it minted at that page's next
frame. `loom access signins PRINCIPAL` and `loom access revoke-login
PRINCIPAL FINGERPRINT` print and send them. The listing's `expires` is
`issued_at_ms` plus thirty days, by rule, and is not stored.

### `principals.list`

Each principal's row gains `logins`, the count of its `active` `browser`
rows. `credential` keeps its meaning: the bearer's state, or the claim's.

### `principals.rename` (optional, last)

```
c→s: {v:2, id, cmd:"principals.rename", body:{principal_id?, name, epoch}}
s→c: {v:2, reply_to, event:"principals.rename", body:{principal_id, name}}
```

A member may omit `principal_id` and renames itself; a member naming
another is `forbidden`. The owner may name any member. The owner's own
name is renamed the same way. Origins already admitted keep the name they
were admitted under (`core/message.gleam:33`).

### Log lines

The daemon logs `daemon.session_created` with `principal_id` and
`session_id` for every creation, from the control endpoint or a page, and
`daemon.login_issued` and `daemon.login_revoked` with `principal_id` and the
login's fingerprint. None carries a name, a path, a token or a key.

### What stays as it was

- Every check on a `Session` page: host, `Sec-Fetch-Site`, `Origin`, the
  page cookie under the key, the page nonce, the credential, the
  membership, the gateway's re-check per frame, the Operator cap, the
  observer component's closed message type.
- The page's three secrets and their scopes; `HttpOnly`, `SameSite=Strict`,
  the key path, the page nonce in `sessionStorage`; `Referrer-Policy:
  no-referrer`; the eight-hour page.
- 053's claim rules 1 to 5; the claim's digest-only storage; `/v2/claim`.
- The session page's invite control and its allowance, now shared with the
  admin page and with device links.
- A page never carries `Owner`. Every owner action a page starts runs
  through `manager.administer` or the control handler's own path with the
  page's credential digest, and the daemon decides.
- The owner token. The owner's login is a `browser` row of the owner
  principal; revoking it leaves `owner.token` as it was.

## Frozen-interface impact

Part 1.6 only.

| Change | Kind |
|---|---|
| `ui.link`: `session_id` optional; `remember` optional; the reply's `path` may be the home exchange | additive |
| New routes `/ui/home`, `/ui/p/<key>/home`, `/ui/p/<key>/home/ws`, `/ui/l/<key>/home` (`GET`, `POST`), `/ui/admin`, `/ui/p/<key>/admin`, `/ui/p/<key>/admin/ws`, `GET` and `POST /ui/claim` | new routes under the prefix 051 fixed |
| `credentials.claim`: optional `name` | additive |
| `principals.list`: `logins` per row | additive |
| New owner-only read `sessions.members` | new command |
| New `credentials.signins`, `credentials.revoke_login` | new commands |
| New `principals.rename` | new command, optional |

The session protocol (Part 1.3) does not change: presence and origins
already carry the current display name. The catalogue schema moves to
version 5; it is not a Part 1 interface (053, "Frozen-interface impact").
`docs/client-protocol.md` §2 (routes), §3 (`ui.link`,
`credentials.claim`, the new commands) and the list of control commands
change to match.

Four rulings in `docs/next.md` are amended, two of them by the owner's
rulings of 2026-10-03: "daemon control stays terminal-only" admits
creation from an owner's operator home; "operator surfaces do not open
saved sessions" admits an operator-ceiling page running the control
command's path (ruled); "053 phase 4 waits for use" is superseded by the
admin page here; and the observer-sidebar ruling is kept for `OneSession`
pages and does not apply to `Workspace` ones, which draw one "Home" control
and no list. A fifth is new: a browser may hold a thirty-day credential
(ruled), bounded as "The browser login" says.

## Impact

- `host/login` (new): the token's grammar, minting, parsing, chain
  verification with `crypto.hmac` and `crypto.secure_compare`, and the
  intersection rules; pure functions over the root key and a clock.
- `client/daemon/root` or `main`: the root key file beside `owner.token`.
- `client/daemon/ui_sessions`: `Scope`, `Reach`, `Remember`, `admin_ms`,
  `device_ms`, the per-scope page bound, `reserve_creation`.
- `client/daemon/ui_http`: the new `Route` variants, the login cookie's
  name and attributes by page origin, the two `POST` bodies' bounds.
- `client/daemon/server`: the routes, `page_grant` by scope, the one
  function that builds a redeemed ticket's response (with or without the
  login), `ui.link` without a session, `sessions.members`,
  `credentials.signins`, `credentials.revoke_login`, `principals.rename`,
  the resume and claim documents, the log lines.
- `client/daemon/ui_socket`: `resume_for`, `home_ticket_for`,
  `device_link_for`, `create_for`, `admin_ticket_for`, the admin and
  sign-in asks; the home and admin sockets' admission rules.
- `client/daemon/manager`, `storage/access`, `storage/catalogue`: `claim`
  with a name and a kind; `members_page`; `signins_page`; `revoke_login`;
  `last_seen`; `rename` exposed; version 5.
- `host/access`, `tui`: `loom access members`, `signins`, `revoke-login`;
  `loom claim --name`; `loom ui` without `--session`, `--observe`,
  `--no-remember`; `--token` refusing `loomb1:`.
- `web_view`: `home`, `admin`, the "Home" control on both session pages,
  saved rows as buttons, the create form, the sign-in rows, the resume and
  claim documents in `page`, endings for a home and an admin page.
- `web_client`: `switch_rule` accepting the home exchange shape; the enter
  script keeping the login nonce; the resume script posting it.
- `docs/architecture/web-view.md`, `multiplayer.md`, `daemon.md`,
  `docs/client-protocol.md`, `docs/next.md`: the rulings and the new pages.

## Verification required

- A `Home` ticket at a session exchange, a session ticket at the home's,
  and either at the admin's are spent and refused; an `Admin` ticket
  redeems only for the owner.
- A home page lists exactly `manager.authorized_page` for its digest; a
  revoked credential's home ends at its next frame; a member's home does
  not draw the create form or the Admin button, and the daemon refuses a
  forged `create` and `admin` from it.
- An observer-ceiling home mints only observer tickets, and its `resume`,
  `create` and `admin` are refused by the daemon whatever the socket
  forwarded.
- An `OneSession` observer page draws no sidebar and no Home control; a
  `Workspace` observer page draws the Home control and no list; a chain
  home, session, home ends at the first home's deadline, and no ticket a
  page mints sets a login.
- `resume` opens a saved session the principal operates and lands on it;
  refuses an observer membership, a `Reserved` and a `RecoveryBlocked`
  row, and an open that outlasts `resume_wait_ms`, each with its fixed
  words and no ticket; a second press while one is out asks nothing.
- `create` makes a session in a listed workspace with the typed name and
  scope and lands on it; refuses an index outside the listing, an invalid
  name, the eleventh creation in an hour; a repeated press makes one.
- The admin page ends at fifteen minutes and the home does not; every
  grant action counts against the allowance shared with the session page
  and device links, a demotion and every revocation do not; a member's
  `sessions.members` is `forbidden`; no frame on the admin socket carries
  `loomclaim_` but the one that shows the owner their invitation.
- The login: a remembered exchange sets the cookie with exactly the
  attributes above for its page origin and the nonce in the body; the
  resume route mints a home the next day and refuses it on the thirtieth;
  a token with a wrong signature, a missing caveat, an unknown name, a
  widening repeat, a key not matching the path, a nonce not matching, or
  an expired `e` is `401` with no catalogue read (the registry stub
  records none); a token narrowed by an appended `c=observer` or an
  earlier `e` verifies and is held to the narrower value; a revoked row is
  `401`; a login on `/v2/control` is `401`; `--token` refuses `loomb1:`;
  deleting the root key and restarting refuses every login; `last_seen_ms`
  moves at most once an hour; a token never appears under the state root
  or in `daemon.log`; a device link redeems once inside `device_ms`, sets a
  login, is listed, and costs one allowance unit; `revoke_login` ends that
  login's pages and no other; `revoke-credentials` and `rotate` end every
  login; a version 4 catalogue migrates to 5 with every credential `bearer`.
- A claim with a `name` binds and the first attach's presence row carries
  it; an invalid name binds nothing and the claim stays open; `loom claim
  --name` sends it.
- `POST /ui/claim` binds a `browser` credential, applies the name, sets
  the login and lands on an operator home; nothing but the digest is under
  the state root; a spent, void, expired or otherwise-bound claim is
  refused in fixed words; a cross-site `POST` is refused at the claim and
  the resume; a bearer-shaped value at the claim is refused before any
  lookup; bodies over 1,024 bytes are refused.
- Mutations, each applied alone and reverted, each fail a named test: a
  member's home offered the Admin button; the admin exchange accepting a
  `Home` ticket; `reserve_invite` skipped for a promotion or a device link;
  `create` accepting a path; `resume` skipping the authority check; the
  chain compared with `==`; the row read before the chain is verified; `e`
  extended on use; a repeated `c` taking the larger; the page cookie given
  a `Max-Age`; a switch ticket minted `Remembered`.

## Cost

- **A thirty-day credential in a browser.** A stolen login is worth
  everything a home at its ceiling can do for a month, until revoked; for
  the owner that includes sessions in known workspaces (ten an hour) and
  admin pages (grants three an hour). Fixed expiry, listing, last-seen,
  per-login revocation and the root key bound it; nothing shortens it.
- **A root key file** the daemon's host must keep private, beside
  `owner.token`, and a credential model with two kinds of row.
- **The catalogue moves to version 5**, so a downgrade needs the catalogue
  restored from before the upgrade.
- **A page starts runtimes.** `resume` and `create` consume registry
  capacity at a browser's request, within the bounds a terminal's open has.
- **Two more page kinds, two more components, two more sockets to review**,
  a login module in `host`, and a scope on every grant where there was a
  session ID.
- **The home reads the catalogue every thirty seconds per open home**, as
  the sidebar does per operator page.
- **A browser-first member who later wants `loom`** needs the owner to
  rotate, which ends their logins; they sign the browser in again with
  `loom ui`.
- **Remote access is still 052's.** Until it lands, the claim form and the
  bookmark work on the daemon's host or through `ssh -L`, and the
  invitation the admin page shows names a loopback address.

## Decision

**Draft.** A session-less home page and an owner's admin page under 051's
ticket, cookie, key and nonce, with the grant's one session replaced by a
scope, a reach and a remember flag; a thirty-day browser login that is a
macaroon-style credential, verified from a root key and the token's own
caveats, stored as one credential row keyed like every other, narrowable
by appending a caveat and revocable by row, by principal or by root key;
a browser claim that binds such a login and takes the invitee's name. An
owner's operator home creates sessions in workspaces the owner already has
sessions in, and any operator-ceiling page opens a saved session through
the control command's own checks. The admin page grants under the session
page's allowance and reduces freely. A key shown once and a sign-in form,
a random-cookie table, rotate-on-use, a free path field, an unbounded
admin page and a second credential kind were considered and not taken.
The owner ruled the lifetime, the macaroon, the known-workspace rule and
the saved-session open on 2026-10-03; the rest of the design note's
answers stand as recommended.

## Open

- **052.** A `Remote(origin)` request should admit `Home` and `Session`
  pages and the login (with the `__Host-` cookie) and never `Admin` or the
  create control; the claim address the admin page shows needs the proxy's
  origin, which is 052's `--ui-origin`.
- **Attenuation in the browser.** The intersection rules are enforced from
  the first cut; a control that appends `s=<session>` and `c=observer` to
  hand out a one-session read-only link needs WebCrypto HMAC in
  `web_client` and a decision on who may.
- **`loom access page`** from 053 phase 4, unbuilt; the home's button
  covers it.
- **Stop from the browser.** One fixed button per running session on the
  owner's home, through `administer`, if asked for.

## Addendum: navigation, the second pull request (2026-10-03)

**Status**: IMPLEMENTED in the change that adds it. It builds the "home row
opens a session" and "Home" controls of the design note's PR 2 and adds no
route, no frozen interface and no kind of wire frame. It does change two
things 065 and 051 said, and says so here.

**The home admits one browser event.** The first pull request's home drew no
handler and its socket admitted no browser frame at all
(`ui_socket.home_accepts` answered `False`). It now admits exactly one event:
a `click`, alone or in a batch, at a path beneath `home.table_path` (the
sessions table's section) or `home.sidebar_path` (the sidebar column), where
the only handlers are the rows of running sessions. Each row's message is
`home.Opening(id)` with the catalogue's identity drawn when the tree was, so a
frame chooses among the rows the page drew and cannot name a session. Every
other frame, a `submit`, a `keydown`, a click on the region's own path or on
any other child of the frame, and a batch containing any of them, is dropped
before it reaches the component. The same holds at either ceiling: an
observer-ceiling home opens observer pages.

**The daemon checks again.** A press asks `ui_socket.ticket_for`, now over a
`Standing` (the registry, credential digest, principal, ceiling and reach of
the asking page): the page must still be open, the identity canonical, the
principal a member of the session (`manager.session_authority`) and the
session resident. A forged press for a session the principal does not hold, one
that does not exist and text that is not an identity are each `NotHeld`; a saved
session is `NotRunning`. The ticket carries the page's credential, principal,
ceiling, deadline and **reach**. The first pull request's `ticket_for` minted
`OneSession` for every switch; a page now carries its own reach onto the pages
it opens, so a page a home opened is a `Workspace` page and a page a link for
one session opened stays `OneSession`.

**The way home.** A session page whose grant has `Workspace` reach, an
observer's included, draws a "Home" button as the top bar's second child, at
`component.home_path`, and its transport holds the capability that mints a
home ticket (`ui_socket.home_capability`, `home_ticket_for`). The press sends
`component.GoingHome`, which carries nothing. The daemon checks that the page
is open and that its credential still authenticates as the page's principal,
and mints a `Home` ticket for that credential, principal and ceiling with the
page's deadline, reach `Workspace` and no login. The three layers 051 keeps for
switching hold here too, each enough alone: the observer component has the one
message only with the capability; the observer's socket admits a click at
exactly `component.home_path` and nowhere new; the daemon refuses from the grant
it holds. A page a link for one session opened (`OneSession`) is handed no
capability and draws nothing: the observer-sidebar ruling for handed-out links
is unchanged, and an observer page opened from one still has no sidebar and no
Home control. An observer `Workspace` page has no list, no sidebar and no
switch, only the Home button.

**The browser.** `switch_rule.target` accepts a second shape,
`/ui/home?ticket=<64 hex digits>`, and nothing else new. Both pages and the
home draw the same hidden `<loom-switch>` as the centre column's last child, so
no admitted path moves with it.

**What a stolen page is worth.** A stolen home page can already list sessions
and mint a ticket for any running session its principal holds, which a stolen
operator session page could do after 051's switching addendum; it now does it
through a click on a row. A stolen `Workspace` session page can mint a home
ticket for its own principal at its own ceiling and deadline, which opens no
session its principal could not already open. A chain of tickets never outlives
the first page's deadline (`mint_before`).
