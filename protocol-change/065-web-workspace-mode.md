# protocol-change/065: a home page, a browser login, a browser claim, session creation and an admin page on the web view

**Status**: DRAFT 2026-10-03, amended the same day for the owner's rulings
(a thirty-day browser login that is itself a macaroon-style credential; a
browser claimant is never shown a key; creation only in a known workspace;
operator-ceiling pages open saved sessions), and again on 2026-10-04 for
the login's security review and two further rulings (the addendum at the
end); PRs 1 to 7 of the plan are on `main`, PR 5 is amended in the last
addendum, and PR 10 (`principals.rename`) is implemented in the addendum
that ends this document · **Affects**:
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
  takes a digest runs unchanged, once every lookup names the credential's
  kind. It can be narrowed later by the daemon appending a caveat.
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
Grant(scope: Scope, credential: Digest, kind: Kind, principal: String,
      ceiling: Role, reach: Reach, remember: Remember)

Scope    = Session(id: String) | Home(origin: Origin) | Admin
Origin   = Fresh | Resumed
Kind     = Bearer | Browser
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
- `kind` names the credential table the grant's digest is looked up in:
  `Bearer` for a ticket `ui.link` minted over a bearer, `Browser` for a
  ticket the login or the claim minted. Every check the page makes passes
  it ("Authentication carries the kind", below).
- `Home(origin)` records how the home was reached: `Fresh` for a `loom
  ui` exchange or a claim, `Resumed` for a home the login minted. A ticket
  a page mints for a switch or the way home carries the minting page's
  origin. Only a `Fresh` home mints an `Admin` ticket or a device link
  (ruled by the owner, 2026-10-04).
- A ticket is redeemed only at the exchange of its scope: a `Session(id)`
  ticket at `/ui/sessions/<id>`, a `Home` ticket at `/ui/home`, an `Admin`
  ticket at `/ui/admin`. Presented elsewhere it is spent and refused, as a
  ticket presented against another session is today (`OtherSession`).

### The browser login

A login is a credential the daemon mints and verifies from a root key, in
the first-party macaroon construction: an identifier, a list of caveats,
and an HMAC-SHA256 chain over them. The browser carries it as a cookie.

**Token.** This is the grammar, written once; the design note's shape
defers to it. The token is ASCII; its parser refuses more than 384 bytes
before reading a field, and refuses an uppercase hex digit anywhere rather
than lowering it.

```
token   = "loomb1:" id ":" caveats ":" sig
id      = 32 lowercase hex digits, the hex encoding of 16 bytes from
          crypto.strong_random_bytes
caveats = caveat *( "|" caveat )              ; at least the six below
caveat  = name "=" value
name    = one byte in [a-z]
value   = 1..128 bytes in [A-Za-z0-9._-]
sig     = 64 lowercase hex digits, the hex encoding of sigN

sig0    = HMAC-SHA256(key: root, data: the ASCII bytes of "loomb1:" <> id)
sigN    = HMAC-SHA256(key: sigN-1, data: the ASCII bytes of caveatN,
                      "name=value" with no separator)

row digest = hex(SHA-256(the 32 ASCII bytes of id))
n          = hex(SHA-256(the 64 ASCII bytes of the nonce as the browser posts it))
```

`:` and `|` are legal cookie-value bytes and outside the value alphabet,
which is the alphabet of a principal ID (`storage/access.gleam:1074`), so
the token parses without escaping. Hashes are over the ASCII text and
never over decoded bytes, which is the convention every digest in the
tree already uses. 384 bytes is the longest token the grammar allows with
a 128-byte principal ID. `gleam_crypto` 1.6.0, already a dependency of
`host`, provides `hmac` and `secure_compare`; no new dependency and no
new FFI.

**Root key.** 32 bytes from `crypto.strong_random_bytes`, written once to
`<state-dir>/browser.key` at mode `0600` with `atomic_write_private`
(`host/bootstrap.gleam:403`) and read at start through
`read_private_bounded` (`host/bootstrap.gleam:359`), the owner-and-`0600`
check `owner.token` is read through. At start: a readable file of exactly
32 bytes is the key; a file that is present but unreadable, of another
size, a link, or another user's refuses start and is never regenerated; a
missing file is drawn fresh and, in the same start, every `active`
`browser` row is marked `revoked` in one update and one line,
`daemon.logins_revoked` with the count, is logged. The key never enters a
token, a log or a reply.

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

**Intersection.** A name may repeat, and a repeat narrows; a wider repeat
is ignored and the narrower value holds: `c` takes the smallest ceiling,
`e` the earliest instant, a future `s` (a session ID) restricts the login
to that session and two different `s` values allow nothing, and `p`, `r`,
`k` and `n` may not repeat with another value. A name the daemon does not
know refuses the token. Attenuation is a daemon act: the cookie is
`HttpOnly`, so no browser script can read a token or extend its chain, and
a narrower token is minted by the daemon from the root key where the wide
one was. Nothing in this change mints one. A token carrying `s` mints only
a session ticket for that session and never a `Home`, since a home's asks
(sign-ins, "sign out everywhere", a device link) are the principal's and
not the session's.

**Storage.** One row in `access_credentials` per login: `digest` as the
grammar defines it, the principal, `state`, and three columns added at
catalogue version 5:

```sql
ALTER TABLE access_credentials ADD COLUMN kind TEXT NOT NULL DEFAULT 'bearer'
  CHECK(kind IN ('bearer', 'browser'));
ALTER TABLE access_credentials ADD COLUMN issued_at_ms INTEGER;
ALTER TABLE access_credentials ADD COLUMN last_resumed_ms INTEGER;
```

The forward migration at `user_version` (`storage/catalogue.gleam:150`)
moves 4 to 5; an older daemon refuses a version 5 catalogue, as 053 says
of version 4. Every existing row is `bearer`. Keying the row by the digest
of the identifier is what lets every existing check run unchanged: a page
minted from a login carries that digest as `Grant.credential`, and
`manager.authenticate`, `session_authority`, `frame_authority` and
`administer` take it as they take a bearer's digest. `revoke_member` and
`rotate_member` revoke `browser` rows as they revoke `bearer` rows.
`storage/access.claim` takes a `kind`, so a browser claim binds a `browser`
row under 053's rules 1 to 5 unchanged.

**Authentication carries the kind.** The identifier is public, and its
digest is the row's key, so without a further rule `Authorization: Bearer
<id>` on `/v2/control` would authenticate as the principal with no caveat
(the review finding of 2026-10-04). The rule, in three layers:

- every place a presented string is hashed into a digest, which is
  `/v2/control`, `/v2/claim` and the session attach (`credential`
  (`client/daemon/server.gleam:718`)), looks up `kind = 'bearer'` rows
  only; a page grant looks up only the kind its ticket names (`Browser`
  for a login's or a claim's ticket, `Bearer` for `ui.link`'s);
- the kind is a parameter of the lookup itself: `access_credential`
  (`storage/sql.gleam:70`) gains `AND kind = ?` and `authenticate`
  (`storage/access.gleam:827`) takes the kind, so no caller can omit it;
- `credential` refuses a presented bearer that is not exactly 64 lowercase
  hex characters before hashing it.

So the bare identifier, the whole token, the identifier's digest and any
string that is not a 64-hex bearer are `401` on every `/v2` route, and a
bearer's digest never satisfies a page grant minted under `Browser`. `loom
--token` and `--token-file` also refuse a value beginning `loomb1:`, as a
courtesy. Two more queries gain `kind = 'bearer'` so a login never stands
in for a bearer in a listing: `principal_active_credential`
(`storage/sql.gleam:273`) and `active_member_credentials`
(`storage/sql.gleam:223`). 053's "rule 3 is what lets `credential` be one
value per principal" (its "Listing principals") holds for bearers; logins
are counted beside it as `logins`.

**Cookie.** On a loopback page origin:

```
loom_login=<token>; HttpOnly; SameSite=Strict; Path=/ui/l/<key>; Max-Age=2592000
```

Under 052's `Remote(origin)`:

```
__Host-loom_login=<token>; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000
```

The page cookie is unchanged and keeps no `Max-Age`. The `__Host-` form has
`Path=/`, so under 052 a browser holds one login per origin: a second
`loom ui` on the same browser overwrites the first's cookie and leaves its
row live until it expires or is revoked, and `k` then names only the row
a resume is for; the sign-in list shows the orphan as not this browser.

Cookies ignore the port and `SameSite=Strict` treats two loopback ports as
one site, so a page on another loopback port can receive the login cookie
if it serves a path under `/ui/l/<key>/` and lures a navigation, which
needs the key, and can make the browser send it to the daemon, which is
refused by `Sec-Fetch-Site` on both the `GET` and the `POST` and by the
nonce. `localhost` and `127.0.0.1` are different cookie hosts; `loom ui`
prints one stable host and the resume page names it.

**Login nonce.** 32 random bytes, hex, delivered once in the body of the
response that sets the login cookie (a remembered exchange, or the claim),
as a `data-login-nonce` attribute beside the page nonce. The enter script
keeps it in `localStorage` under `loom.login.<key>` and the page nonce in
`sessionStorage` as today. The daemon keeps its digest as caveat `n` and
nothing else. `n` buys two things: a cookie planted by another port cannot
fix the person to an attacker's login, since the attacker's token carries
the attacker's `k` and the victim holds no nonce under it; and a
disclosure of the cookie jar alone (a cookie file, a `Cookie` header in a
proxy or a log under 052) is useless without it. It buys nothing against a
profile read, nothing beyond `Sec-Fetch-Site` against a cross-port
request, and nothing against 052's proxy operator, who sees cookie and
nonce alike and is in the trusted computing base.

**Verification**, at `POST /ui/l/<key>/home`, in this order, each refusal
`401` with a fixed document and no echo: every value of the cookie named
for the page origin is tried, up to four, in the order the browser sent
them, and the first that parses as the grammar and whose chain recomputes
from the root key with `secure_compare` matching `sig` is the login (a
value planted under a longer path sorts first and is passed over); every
caveat of that token holds (`k` equals the path's key, `n` equals the
SHA-256 of the body's `nonce`, `e` is after now, no unknown name; a wider
repeat is ignored); the row for its digest is found, `active` and
`browser`, and its principal is `p`. The catalogue is not consulted before
a chain verifies. The daemon then mints and redeems a `Home(Resumed)`
grant (`credential` the row's digest, `kind: Browser`, `ceiling` from `c`,
`reach: Workspace`, `remember: Forgotten`) and answers the enter page. It
logs `daemon.login_resumed` with the login's fingerprint and writes
`last_resumed_ms` when the row's value is older than an hour.

**Device link.** A `Home(Fresh)` ticket with `remember: Remembered` and the
lifetime `device_ms`, minted by `ui_socket.device_link_for` only for a
`Home(Fresh)` page, for its own principal and ceiling, counted against the
credential's grant allowance (`reserve_invite`, three an hour), and shown
once as an absolute exchange address in a copy box. Its exchange sets a
login on the device that opens it. When the minting page was itself opened
by a remembered exchange, the new login's `e` is the issuing login's `e`,
so a family of logins ends with the one it began from; a page with no
issuing login (a `loom ui --no-remember` home) gives a full thirty days.
A `Home(Resumed)` page draws no device-link control and the daemon
refuses `device_link()` from one (ruled by the owner, 2026-10-04).

**Logging.** No token, root key, nonce or login key is ever logged. The
daemon logs `daemon.login_issued` with the principal ID, the new login's
fingerprint and, when there is one, the issuing login's fingerprint;
`daemon.login_resumed` and `daemon.login_revoked` with the principal ID
and the login's fingerprint; and `daemon.logins_revoked` with a count at a
start that drew a new root key.

### Routes

All under 051's prefix, host-checked first, with 051's headers and policy.
`<key>` and the page cookie are 051's; the page cookie's path is
`/ui/p/<key>`.

| Method and path | Checks, in order | Answer |
|---|---|---|
| `GET /ui/home?ticket=<t>` | loopback host; `Sec-Fetch-Site` `none` or `same-origin`; redeem a `Home` ticket | the enter page; the page cookie; the page nonce in the body; for a `Remembered` ticket also the login cookie and the login nonce |
| `GET /ui/p/<key>/home` | host; `Sec-Fetch-Site`; page cookie under the key names a live `Home` page; credential authenticates | the shell |
| `GET /ui/p/<key>/home/ws?csrf-token=<n>` | host; `Origin` is `http://` and the `Host`; page nonce; page cookie; credential | the home socket |
| `GET /ui/l/<key>/home` | host; `Sec-Fetch-Site` `none` or `same-origin`; `<key>` is 32 hex | the fixed resume page, whose script posts the login nonce from `localStorage` to the same path; served with `form-action 'self'` |
| `POST /ui/l/<key>/home` | host; `Sec-Fetch-Site` `same-origin`; body at most 1,024 bytes, `application/x-www-form-urlencoded`; the login verifies | the enter page for a new `Home(Resumed)` grant |
| `GET /ui/admin?ticket=<t>` | as the home exchange, for an `Admin` ticket | the enter page |
| `GET /ui/p/<key>/admin` | as the home page, for an `Admin` page, and the credential is the owner's | the shell |
| `GET /ui/p/<key>/admin/ws?csrf-token=<n>` | as the home socket, and the owner | the admin socket |
| `GET /ui/claim` | host; `Sec-Fetch-Site` `none` or `same-origin` | a fixed document with the two fields, served with `form-action 'self'` |
| `POST /ui/claim` | host; `Sec-Fetch-Site` `none` or `same-origin`; body at most 1,024 bytes; `token` is `loomclaim_` and 64 hex; `name` empty or valid; the claim redeems | the enter page for a new `Home` grant, with the login cookie and nonce |

The page and socket of a `Session` grant are unchanged. A `Home` and an
`Admin` grant have no session, so their `page_grant` checks the page
cookie, the key and the credential, and the admin's additionally that the
principal's kind is `OwnerPrincipal`; the membership check is skipped.

The resume page and the claim form are the only two `/ui` documents whose
policy says `form-action 'self'`; every other document keeps
`form-action 'none'` (`content_security_policy` (`web_view/page.gleam:314`)),
and nothing else in the policy widens for them.

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
| `device_link()` | `Home(Fresh)`, any ceiling | `reserve_invite`; mint a `Remembered` `Home(Fresh)` ticket living `device_ms` with the page's principal and ceiling, and the issuing login's `e` when there is one; refused from a `Home(Resumed)` page |
| `create(index, name, scope)` | `Owning` `Home` page | resolve `index` against the listing this socket last drew; `name` as `valid_name`; `scope` `workspace_private` or `session_only`; key `page-<serial>-<n>`; `manager.create_scoped` with configuration `""`; then `resume(id)`; counted by `reserve_creation` (ten an hour per credential) |
| `admin()` | `Owning` `Home(Fresh)` page | mint an `Admin` ticket with the page's principal and deadline; refused from a `Home(Resumed)` page, which draws no Admin button |
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

`name`, when present, is trimmed and must then pass the catalogue's
display-name rule (nonblank, at most 256 bytes, no control characters,
`valid_name` in `storage/access.gleam`), else `invalid_name` and the claim
binds nothing and stays open; a `name` that is not text is `bad_request`.
`invalid_name` is a new refusal code on `/v2/claim` only; the first draft
of this section reused `bad_request`, which cannot tell a client that its
message was malformed from one that must ask the invitee for another name.
When the name passes, `storage/access.claim` sets the principal's
`display_name` in the transaction that binds the credential, after every
other check and before the first write. Only the redemption that binds
applies it: the replay of a lost reply, with the same digest, answers the
principal as it stands and never renames, whatever `name` it carries.
`loom claim --name NAME` sends it, and the stored credential survives an
`invalid_name` so that a rerun with another name redeems the same claim. The browser claim (`POST /ui/claim`)
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
            signins:[{fingerprint:"<16 hex>", issued_at_ms, last_resumed_ms?,
                      issued_by?:"<16 hex>"}],
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
`issued_at_ms` plus thirty days, by rule, and is not stored; `issued_by`
is the fingerprint of the login whose device link this one came from,
when there was one, so a family is traceable from any member.

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
| Authentication by kind: a bearer presented on `/v2/control`, `/v2/claim` or a session attach is exactly 64 lowercase hex and matches only a `bearer` credential; a login matches only a `browser` one | a rule Part 1.6 states; every bearer issued today already has that shape |
| The resume page and the claim form are served with `form-action 'self'` | a header rule under 051's prefix |
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
- `client/daemon/root` or `main`: the root key file beside `owner.token`,
  its three start-time cases, and the revocation a fresh key performs.
- `client/daemon/server`: `credential` refusing a bearer that is not 64
  lowercase hex, and every wire-bearer lookup naming `bearer`.
- `client/daemon/ui_sessions`: `Scope` with `Home(origin)`, `Kind`,
  `Reach`, `Remember`, `admin_ms`, `device_ms`, the per-scope page bound,
  `reserve_creation`.
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
- `client/daemon/manager`, `storage/access`, `storage/catalogue`,
  `storage/sql`: `authenticate` and `access_credential` taking the kind;
  `principal_active_credential` and `active_member_credentials` restricted
  to `bearer`; `claim` with a name and a kind; `members_page`;
  `signins_page`; `revoke_login`; `last_resumed`; `rename` exposed;
  version 5.
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
- Credential kinds: a version 4 catalogue migrates to 5 with every
  credential `bearer`; a `browser` row authenticates on no `/v2` route and
  under no `Bearer` page grant, and a `bearer` row under no `Browser`
  grant; a 32-character, a 63-character and an uppercase-hex bearer are
  `401` before the catalogue is read; `principals.list` for a principal
  holding one `bearer` and one `browser` row reports the bearer and
  `logins: 1`.
- The login: a remembered exchange sets the cookie with exactly the
  attributes above for its page origin and the nonce in the body; the
  resume route mints a `Home(Resumed)` the next day and refuses it on the
  thirtieth; a token with a wrong signature, a missing caveat, an unknown
  name, uppercase hex anywhere, more than 384 bytes, a key not matching
  the path, a nonce not matching, or an expired `e` is `401`, with no
  catalogue read for the first five (the registry stub records none); a
  wider repeat is ignored and the narrower value holds; a token narrowed by
  an appended `c=observer` or an earlier `e` verifies and is held to the
  narrower value, and one carrying `s` mints a session ticket for that
  session and no `Home`; a revoked row is `401`; the bare identifier, the
  whole token and the identifier's digest presented as a bearer on
  `/v2/control` are each `401`; `--token` refuses `loomb1:`; a planted
  `loom_login` under a longer path does not deny the real one, and a
  fifth value is not read; a missing root key at start refuses every login
  and marks every `browser` row revoked with one log line, and a truncated
  or group-readable key file refuses start; `last_resumed_ms` moves at
  most once an hour and `daemon.login_resumed` is logged on every resume;
  a token never appears under the state root or in `daemon.log`; a
  `Home(Resumed)` draws no Admin button and no device-link control and the
  daemon refuses `admin()` and `device_link()` from it; a device link
  redeems once inside `device_ms`, sets a login whose `e` is the issuing
  login's, is listed with `issued_by`, is logged with its parent's
  fingerprint, and costs one allowance unit; `revoke_login` ends that
  login's pages and no other; `revoke-credentials` and `rotate` end every
  login; the resume and claim documents carry `form-action 'self'` and
  every other `/ui` document `'none'`.
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
  a `Max-Age`; a switch ticket minted `Remembered`; the kind dropped from
  the `authenticate` query (the bare identifier then authenticates, and
  the test must fail); the 64-hex shape check removed from `credential`;
  `principal_active_credential` without its kind; a `Home(Resumed)`
  offered the Admin button or a device link; a device-link login given
  thirty days under an issuing login; a fresh root key drawn without the
  revocation; only the first `loom_login` value read; the resume document
  served with `form-action 'none'`.

## Cost

- **A thirty-day credential in a browser.** A stolen login is worth
  everything a resumed home at its ceiling can do for a month, until
  revoked; for the owner that includes sessions in known workspaces (ten
  an hour) but no admin page and no device link, which only a fresh home
  mints. Fixed expiry, listing, last-resumed, per-login revocation and the
  root key bound it; nothing shortens it.
- **A stolen fresh home is worth a login.** Inside its eight hours it can
  mint a device link, three an hour, and each is a thirty-day credential
  at the page's ceiling until revoked, listed and traceable to its parent;
  051's eight-hour price no longer covers a fresh home on its own.
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
the saved-session open on 2026-10-03, and on 2026-10-04 that the admin
page and device links come only from a fresh home; the rest of the design
note's answers stand as recommended. The security review of 2026-10-04
(the addendum below) changed the credential model so that the login's
public identifier authenticates nothing, and bounded the root key, device
links and the resume as the addendum records.

## Open

- **052.** A `Remote(origin)` request should admit `Home` and `Session`
  pages and the login (with the `__Host-` cookie) and never `Admin` or the
  create control; the claim address the admin page shows needs the proxy's
  origin, which is 052's `--ui-origin`.
- **Narrowed tokens.** The intersection rules are enforced from the first
  cut; a daemon-side control that mints a token with `s=<session>` and
  `c=observer`, to hand out a one-session read-only link, needs a decision
  on who may ask and a page kind for what the holder reaches, since such
  a token mints no `Home`.
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

## Addendum: the login security review (2026-10-04)

**Status**: folded into the proposal above; the body reads as amended, and
this addendum records what moved and why, in the order the review found
it. The owner ruled two of its questions on 2026-10-04.

### Problem

The review of the macaroon login found one defect and three trade-offs.
The defect: the login row was keyed by the digest of the token's public
identifier, and every wire-bearer path hashes any presented string into a
digest with no shape check and no kind, so the identifier alone, which
every holder of the cookie can read, would have authenticated on
`/v2/control` as the principal with none of the token's caveats. For the
owner's login that is owner authority. The trade-offs: a device link from
any home turned a stolen eight-hour page into a thirty-day credential; an
admin page re-mintable from a resumed home made 053's fifteen minutes a
page lifetime rather than a credential bound; and a regenerated root key
left every revoked login listed as live. The rest were clarity: the
grammar in two places with two sizes, a CSP that would have blocked the
two forms, a planted cookie denying the resume, a column named for more
than it recorded, and queries that assume one active credential.

### What was considered

For the defect, keying the row by `HMAC-SHA256(root, id)` so no
presentable string hashes to it was considered; it couples every row to
the root key, and the kind filter is the smaller change and uses the
column the catalogue is gaining anyway. For the admin page, three answers
were offered: accept the thirty days and say so; a `Fresh | Resumed`
origin on the home grant with `Admin` minted only from `Fresh`; or a
shorter `e` for the owner's logins. The owner chose the origin. For device
links, the same origin, an inherited `e` and a logged parent.

### Decision

- Authentication carries the credential kind, in the query; a presented
  bearer is 64 lowercase hex or `401` before any lookup; the two
  one-credential queries name `bearer`. This is its own pull request,
  ahead of the login, so it is reviewed alone.
- `Home` grants carry `Fresh | Resumed`; `Admin` tickets and device links
  are minted only from `Fresh` (ruled by the owner, 2026-10-04); a
  device-link login inherits the issuing login's `e`; `daemon.login_issued`
  names the parent, and `credentials.signins` reports it as `issued_by`.
- A missing root key is drawn and every `browser` row revoked in the same
  start; an unreadable or wrong-sized key refuses start; the key is read
  through `read_private_bounded` and written with `atomic_write_private`.
- Attenuation is a daemon act; a token with `s` mints no `Home`.
- The two form documents carry `form-action 'self'`; the grammar is
  written once with byte-level hash inputs, a 384-byte bound, uppercase
  refused, and "a wider repeat is ignored"; up to four `loom_login` values
  are tried; `last_resumed_ms` replaces `last_seen_ms` and
  `daemon.login_resumed` is logged per resume; `__Host-` means one login
  per origin under 052; the ports and the nonce are stated plainly.

### Cost

A stolen fresh home is now priced as a login, which is the true price and
was not stated before. The owner runs `loom ui` on a day they administer
or add a device, which is one command. One more field on the home grant,
one more kind on every credential lookup, and a start-time rule for one
file.

## Addendum: opening a saved session, the third pull request (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it. It builds the design note's
PR 3 and adds no route, no frozen interface and no kind of wire frame. It
amends a ruling and says so here.

**The ruling it amends.** `docs/next.md` held "operator surfaces do not open
saved sessions". The owner lifted that on 2026-10-03 for operator-ceiling pages
through the control command's own checks (section 9 of the design note). This
change is that lift, and `docs/next.md` now says so under the ruling's new
heading: a listing is still never permission, and the principal's role in the
target is. The observer-sidebar ruling is untouched.

**The press.** A saved session's row is a button on a home or a session page
minted to operate, beneath the same two regions as before
(`home.table_path`, `home.sidebar_path` on the home; `component.sidebar_path` on
a session page), so no socket admits a new path. Its message is
`home.Resuming(id)` or `operator_page.Resuming(id)` with the catalogue's
identity. A session the catalogue reports as `Reserved` or `RecoveryBlocked` is
`sessions.Blocked` and its row stays text at every ceiling. `view/resume` holds
the one rule for which row is a button, drawn "opening" while its resume is out
and text for every other saved row, so a second press has no handler; the
components ignore one too (`resuming` is set until the answer arrives).

**The daemon.** `ui_socket.resume_for(standing, tickets, open, target, within:)`
runs, afresh and from the grant the daemon holds: the page is still open; its
ceiling is Operator; `target` is a canonical identity; `session_authority`
finds Owner or `Participant(Operator)` (an observer member is `NotOperator`, the
control command's own refusal, and a principal with no membership is `NotHeld`);
`manager.open`, the registry turn `sessions.open` runs (capacity, a reserved
creation, an archived session, the domain slot), whose refusals are all
`NotOpened`; a `weft/poll` over `manager.get` until the session is `Resident`,
for at most `resume_wait_ms` (30,000), where `Opening` retries and any other
status or an unreadable registry ends the wait; and then `ticket_for`, which
checks the page, the membership and the residency a second time and mints with
the page's own ceiling, reach and deadline. A session that is not resident in
time mints nothing. The registry may still finish the open, and the session
then shows as running on the next read.

The control command also compares the daemon epoch the client holds. A page
holds none to compare: its UI session lives in this daemon's memory, so a page
for which `open()` still answers was admitted by this daemon, and `open()` is
the epoch check.

**The task.** The wait is long, so `ui_socket.resume_task` runs `resume_for` in
a weft run of its own (one task, no deadline, `start_witnessed`, linked to the calling Lustre runtime so a page that goes
away cancels it) and returns at once. The task's last act is the answer, which
the component dispatches as `Linked`, the same message a switch's answer is.
`Transport.resume` and `home.Start.resume` have the shape `fn(String,
fn(Answer) -> Nil) -> Nil` for this. The run has no deadline: every step of `resume_for` is
bounded by its own call timeouts, so the task answers within about a minute, and
a deadline could only kill a task that would have answered. Only a page that
closes mid-open loses the answer, and then nobody is looking.

**The refusals.** Two reasons join `sessions.Reason`. `NotOperator` is "Ask an
operator to resume it." and `NotOpened` is "That session did not open. Resume it
from a terminal." No text from the open reaches the page. An observer-ceiling
page's forged press, and an observer-role session page's, is `NotHeld`, the
words for a session the principal does not hold: the home's observer variant
drops the message (`ObserverCeiling`), the observer page's component has no
resume, `resumed_for(Observing, ..)` refuses before any task starts, and
`resume_for` refuses a non-Operator ceiling. Each layer is enough alone.

**What a stolen page is worth.** A stolen operator-ceiling page can already
list the principal's sessions and mint a ticket for any running one. It can now
also ask the daemon to open a saved session its principal operates or owns, which
the principal's own `loom` could already do through `sessions.open`. It consumes
registry capacity at a browser's request, within the bounds a terminal's open
has, and cannot open a session the principal only observes or does not hold.

## Addendum: the home as a session list (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it. It is the round-3 critique's
batch B10 (F57, F58 in part, F70). It adds no route, no frozen interface and no
kind of wire frame, and the socket admits exactly the clicks it did.

**The list.** The home's centre is one list for each workspace, not a table. A
workspace is a heading (its path with the owner's home directory written `~`,
the whole path in `title`, and the session count) over a `ul`; a session is one
`li` holding a glyph, the name, and under it a quiet line: `resident · working ·
created 2h ago` for a running session and `saved · 2h ago` for one on disk.
`home.table_path` is unchanged (`0\t2\t1`): `home_table.view` is still the one
section that is the centre's second child, and every handler is still a button
beneath it, one for each pressable row, so `ui_socket.home_accepts` admits the
same paths and `home_test` pins the count of buttons as before. A running row
and a saved row on an operator page open on press, as before; a saved row on an
observer page, a blocked row, and a row whose resume is out are the same words
in a block with no handler. The age is counted from `Start.now`, read once for
each list, and the exact UTC minute is the `time` element's `title`. A session's
name and the principal's name are text nodes only. A workspace's path is a text
node and, whole, the group heading's `title`, as on the session page's heading;
both are the owner's and the host's catalogue fields, never a session agent's.

**The bar and the Home entry.** The bar is the session bar's: the status is the
`pill` with the page's `Tone` (online, pending, ended), the principal is in the
bar's sans face, and the ceiling is a quiet pill. Nothing on it is monospaced.
The sidebar's `Home` entry carries a fixed house glyph (inline SVG, no text, no
value from the page) and is tinted, not boxed, when it is the page on screen.

**Activity.** `sessions.activity` (protocol-change/050) says what a running
session is doing. The home asks for it for the running sessions its own list
holds, at most `home.activity_limit` (24, the command's own bound), every time
a list answers. The read is `Start.activity`, of the shape `fn(List(String),
fn(List(#(String, Activity))) -> Nil) -> Nil`: it returns at once, as `resume`
does, and the answer arrives as `Observed` from a task. `ui_socket.activity_task`
runs the daemon's read in a weft run linked to the Lustre runtime, so the
runtime never waits for a session to answer, and a page that goes away cancels
the read. The read is `server.activity`, the control command's own function, with
its own bounds: one 2,000 ms deadline over every session asked, a row cut to
2,400 bytes, and an `unknown` row for a session that did not answer. Only the
state word leaves the daemon (`needs_you`, `working`, `idle`, drawn as `needs
you`, `working`, `idle`); `last_message`, `model` and the glances are dropped
before the page sees them, and a state the page does not know is no activity.
The page draws its list first and the words when they arrive; a row with no
answer says only `resident`.

**Who is asked.** Every principal's home asks, and is answered only for the
sessions its credential holds. The owner ruled on 2026-10-04 that a member sees
the activity of sessions it belongs to, and protocol-change/050 carries the
amending addendum: `server.home_activity` re-derives membership in the registry
at each read from the page's credential digest (`held`), never from the page's
list, and an id the credential does not hold is dropped as an unknown id is. The
control command `sessions.activity` answers a member the same way.

**The expired page (F70).** The document a refused request is answered with
(`page.refusal`, `page.home_refusal`) carries the brand, the headline, the
advice's lead and, where a fresh link helps, the command that mints one in a
`<loom-copy subject="link">`, with the same command in a `code` element inside it
for a browser without scripts. `ending.Advice` splits the sentence the live
notice says into `lead` and `command`; `advice` is `lead`, then "Run `command`
for a fresh link.", so the live notice's words did not change in kind, and a
few connectives did ("If it stays closed, it needs a new link."). `<loom-copy>`
gains a third subject word, `link`, whose text it copies only if it is `loom ui`
or `loom ui --session ` and a session identity of hexadecimal digits and hyphens,
at most 64: the same rule, and the same refusal of a newline or a second command,
the two invitation texts have. The document now loads the client bundle, the
page's own file from this origin, so the policy is the one every `/ui` response
has. The "Go to home" button waits for the browser login.

**Subtitles (F58), not built.** The critique's subtitle is the first prompt's
first 60 characters. The catalogue has no such field and the home has no prompt
on the wire, so building it needs a column and a wire field, which this change
does not add. The row's second line is the creation age until that is decided.
The smallest design is recorded in the pull request that made this change.

**Cost.** A home page with running sessions asks them what they are
doing once for each list, every 30 seconds by default. Each ask is
a call into the session's Agency actor and delays that session's other peer
commands by the time its reads take, which is 050's own cost, paid at the
interval of a page that is open, for at most 24 sessions. A page with no running
session asks nothing.

## Addendum: creating a session, the fourth pull request (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it. It builds the design note's
PR 4 and the round-3 critique's F55, and adds no route, no frozen interface and
no kind of wire frame. It adds one admitted event kind to one socket, and says so
here.

**The control.** On the home of the daemon's owner, minted to operate, each
workspace's heading has a "New session" button. It opens one form under that
workspace: an optional name, a "Shareable" checkbox, Create and Cancel. The
workspace is never typed. It is the catalogue's own text for a workspace the
owner already has a session in, carried by the message the server drew into the
tree, so the browser's event names only the path it fired at. Left blank, the
name is the workspace's folder name, as the terminal names a session. Every other
home draws nothing: `ui_socket.home_create_capability` gives `Start.create` to a
principal of kind owner at ceiling Operator and to no other, and the component
ignores the creation messages without it.

**F55.** The checkbox is the sharing choice at creation. Ticked, the session is
created `session_only`, which is the scope an invitation needs (`NotIsolated`
otherwise), so the owner who ticks it can invite from the new session's page
without a terminal. Unticked, it is `workspace_private`, the terminal's default.
The design note already ruled the box (section 2.2, "shareable"), so this makes
no new decision. The box words what it allows, not the scope's name.

**The admission.** The home's socket admitted clicks alone. The owner's home also
admits a `submit` beneath `home.table_path`, where the form is. That is the
admission protocol-change/067 added for the rename form
(`ui_socket.home_owner_accepts`), and the two share it: the socket admits a
submit for the owner's operating home, which holds both capabilities on one
condition, and every other home keeps `home_accepts`. The socket cannot tell the
forms apart and does not try. They sit at different paths, each has its own
decoder, and each decoder refuses the other's fields (`text` against `name` and
`shareable`), so a submit reaches only the handler drawn at its path. The
two regions are unchanged and no pinned path moved: `strip_path`, `invite_path`,
`session_controls_path`, `older_path`, `sidebar_path`, `home_path` and
`home.table_path` are as they were, and `ui_socket_test` pins the owner's
admission, the plain home's refusal of the same frame, and the owner's refusal of
a submit anywhere else, of every other event kind and of a batch holding one.

**The daemon.** `ui_socket.create_for` runs the control command's
`sessions.create` on the page's behalf. The command's body is now
`server.create_session`, which both call, so the owner check, the canonical
workspace and configuration and the registry's own creation are one function.
Each step is the daemon's and is made afresh, with the digest of the credential
the page was admitted under: the page is still open (which is also the epoch
check, since a page's UI session lives in this daemon's memory and no earlier
daemon's page answers); the ceiling is Operator; the credential authenticates as
the principal the page was admitted for and that principal is the owner (each is
`NotOwner`); the name passes `creations.chosen_name` (nonblank after trimming, at
most 256 bytes, unchanged by `text_hygiene.single_line`); the workspace is one
the owner's own `authorized_page` read lists (`NotKnown`); and the credential has
a creation left (`ui_sessions.reserve_creation`, ten in an hour, counted apart
from invitations, `TooMany`). A refusal before the allowance costs nothing; a
refusal after it keeps the place, since a reply that timed out may have created.
Then `create` makes the session under a key drawn for the call, `web-` and
sixteen random bytes in hex, so no retry or repeat can return another creation's
session. `daemon.session_created` is logged with the principal and the session, as
`daemon.upgrade_*` lines are, so a run of creations from a page shows in
`daemon.log`. The session is then opened and ticketed as a resume's is
(`opened_ticket`, shared with `resume_for`): the registry's open, a bounded wait
for residency, and a ticket with the page's own ceiling, reach and deadline. A
session that was created and did not open is `NotOpened`, in words that say it
exists and will appear in the list.

**The task.** The call can wait a minute, so `ui_socket.create_task` runs
`create_for` in a weft run of its own, linked to the Lustre runtime, and returns
at once. The answer arrives as `home.Created`, the effect's own message, which no
handler carries. The component holds one creation at a time (`Waiting`): the
form is drawn disabled, no button has a handler, and a second submit asks
nothing, so a repeated press creates once; the key above makes a forged second
request a second session, which the allowance bounds.

**What a stolen page is worth.** A stolen owner home, fresh or resumed, can now
create sessions in workspaces the owner already runs agents in, ten an hour, and
prompt them at operator role; this is design note section 2.4's account and not
more. It cannot name a path: a frame that names a directory the owner holds no
session in is `NotKnown` and creates nothing. A member's or an observer-ceiling
home draws no control, admits no submit and is refused by the daemon from the
grant it holds, each layer enough alone.

**Cost.** One event kind on one socket, `server.create_session` split out of the
control command's dispatch, one more allowance table in `ui_sessions`, and a form
on the owner's home.

## Addendum: credential kinds, the seventh pull request (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it. It builds the design note's
PR 7 and changes no frozen interface; the catalogue schema is not a Part 1
contract.

**What it builds.** The `kind`, `issued_at_ms` and `last_resumed_ms` columns of
the "Storage" section, as the migration `sql/catalogue_credential_kinds.sql`.
`access.authenticate` and `access.claim` take a `CredentialKind`;
`access_credential` carries `AND kind = ?`; `principal_active_credential` and
`active_member_credentials` carry `kind = 'bearer'`; and `credential` in
`client/daemon/server.gleam` refuses a presented bearer that is not 64
lowercase hex before hashing it.

**The smallest reading, and where it stops.** No browser login exists yet, so
every grant is `ui.link`'s and every wire path is a bearer: the manager fixes
`Bearer` in one function, `bearer_principal`, and a grant will carry its kind
when PR 8 mints the first `Browser` grant. A digest is one primary key across
both kinds, so the checks that a digest is free (`create_member`, enrollment,
`claim`, `rotate_credential`) and `revoke_credential` ask both kinds; only an
authentication names one. The shape check reuses `access.credential_digest`,
since a credential and a digest are the same 64-character shape.

**The version number.** The sections above say version 5 because `main` was
at 4 when they were written. The session-subtitle change (#806) landed first
with version 5, so this change is catalogue version 6: `kind`, `issued_at_ms`
and `last_resumed_ms` arrive at `user_version` 6, and "moves 4 to 5" reads as
"moves 5 to 6".

**What it costs an existing enrollment.** A digest-enrolled secret that is not
64 lowercase hex no longer authenticates after this change, because the daemon
refuses such a bearer before hashing it. `loom enroll` and `loom claim` draw
64-hex secrets, so only a hand-made digest is affected; re-enroll it with `loom
enroll`.

**Left for PR 8.** `claim`'s `bind` runs `no_active_credential`, which counts
`bearer` rows only, for a `Browser` bind as well. That is correct for PR 7,
where only a bearer claim exists in production. PR 8 must make it kind-aware, so
that a login is counted beside the bearer and never in its place.

**One version constant.** `storage/catalogue.gleam` names `current_version`
once, and a test asserts it equals the highest migration, so a second change
that adds a migration and forgets to raise it fails a test.

## Addendum: the admin page, the fifth pull request (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it. It builds the design note's
PR 5 (`sessions.members` and the admin page), adds one control command, one
`Scope`, three `/ui` routes, one admitted event path on the owner's home and one
admitted region on a new socket, and says here what each admits.

**`sessions.members`.** The owner-only read of who holds one session, with its
SQL (`SessionMembers` in `storage/sql/access.sql`, regenerated by `make gen-sql`),
`storage/access.session_members_page`, `manager.session_member_page` and
`loom access members SESSION [--after PRINCIPAL]`. It is a `ControlRead`, refused
`forbidden` for a member exactly as `principals.memberships` is (the owner check
runs in the dispatch ahead of any read, after the decoder has judged the wire
shape, as for every command), and bounded as it is: at most 100 rows and 60,000
bytes a page, `next` the last principal. An unknown session is `not_found`. The
query reads `access_memberships` by session, which its primary key does not
index, so it scans the table; the table holds one row for each invitee and
session and the call is the owner's alone, so the scan is accepted rather than
adding an index and a catalogue version. `docs/client-protocol.md` §3.25 has the
wire.

**`Scope.Admin`.** A third scope with its own exchange (`/ui/admin?ticket=`), page
(`/ui/p/<key>/admin`) and socket (`.../admin/ws`), routed by `ui_http.route` as
`AdminExchange`, `AdminPage` and `AdminSocket`. A ticket redeems only at the
exchange of its own scope, which `ui_sessions.redeem` already read as
`grant.scope != scope`, so a session's ticket and a home's are spent and refused
at the admin exchange and an admin ticket is spent and refused at theirs, each
adding no page. An admin page lives `ui_sessions.admin_ms` (fifteen minutes) from
its exchange, or the minting home's deadline if that is earlier
(`mint_before`), and never longer than the table's own page lifetime; the home
that minted it is unaffected when it ends. The cap of `max_pages` live pages is
counted for `Admin` apart from `Home` and each `Session`.

**The button, and who is offered it.** The owner's home draws an "Admin" button as
the last child of its top bar (`home_bar.admin`, `home.admin_path`, `"0\t0\t5"`).
`ui_socket.home_admin_capability` hands `Start.admin` to a home whose principal is
the daemon's owner, minted to operate, and fresh, and to no other; a home without
it draws nothing and ignores the message, and a page that is still connecting or
has ended draws none. The freshness rule of the design note's section 4.3 is one
function, `ui_socket.fresh_home`, which the capability and `admin_ticket_for` both
ask. Until the browser login exists a home is only ever opened by a `loom ui`
exchange, so it reads the home's reach and every home is fresh; the login's pull
request narrows that one function and nothing around it.

**The ticket.** `ui_socket.admin_ticket_for` re-derives the page at the press:
it is still open, minted to operate and fresh; its credential still authenticates
as the principal it was admitted for, and that principal is the owner. The ticket
carries the home's credential, principal and ceiling and its deadline, and every
refusal is `NoAdmin`, whose words do not say which step failed.
`admin_ticket_task` runs it in a weft run and the answer arrives as
`home.AdminLinked`; the ticket departs through the same hidden `<loom-switch>`,
whose `switch_rule.target` accepts `/ui/admin?ticket=<64 hex>` as its third
address shape and nothing else. The server's `admin_grant` checks, at every page
and socket request, the cookie's grant is of the `Admin` scope and its credential
still authenticates as the owner, so a credential that was the owner's when the
page opened and is not now ends the page at its next request.

**The page.** `web_view/admin` is a server component in the home's frame
(`shell.Home`, no sidebar, no panel). `web_view/grants` holds its vocabulary and
every refusal's fixed words. It lists the principals with each one's credential
state in words (`active` with the fingerprint and when a claim bound it, `invited`
with the time the claim has left, `invitation expired`, `no credential`), the
invitations waiting to be claimed, the owner's sessions, and a chosen session's
members with the changes the owner makes to each. Reads and changes both run in
weft tasks (`admin_read_task`, `admin_task`) so the Lustre runtime never waits on
the registry, and the page holds one change at a time: every button is drawn
disabled while one is out, a read's number is how an overtaken answer is
recognised and dropped, and a change is followed by a read. A claim an invitation
or a rotation makes is held in the component until the owner hides it and drawn
once in the session page's own copy boxes; the catalogue holds only a claim's
digest, so no read carries one, and no frame of the admin socket carries
`loomclaim_` except the one that shows the owner a claim they just made. The
sign-in rows and their revoke are the browser login's.

**The five changes, and the one allowance.** `ui_socket.admin_for` makes each
afresh from the grant: the page is open, its ceiling is Operator, and the
credential authenticates as the principal it was admitted for and that principal
is the owner (`NotOwner` for each), and then `manager.administer`, which
authenticates the credential and the epoch again. An invitation, a rotation and a
role raised to operator are grants and each takes one place from
`ui_sessions.reserve_invite`, the allowance the session page's invitation control
is held to, counted for the credential and not for any page: the fourth grant in
an hour across the admin page and a session page is `TooMany`. Lowering a role,
removing a membership and revoking credentials only reduce access and cost
nothing. A refusal that made nothing gives the place back and an unknown outcome
keeps it, as `invite_for` does, and both go through the one `give_back`. A role
raised to operator is counted whatever the member held, where the design note
counts it only when the member was an observer: reading the held role first is a
second registry call, and the only case it saves a place in is a request that
changes nothing. An invitation's name is the owner's suggestion, judged by
`catalogue.display_name` before the allowance is taken, and the invitation itself
is the session page's own dispatch (`invitation`), so a claim and its principal
are made one way whichever page asked.

**The admissions.** The owner's home that holds the capability gets
`home_admin_accepts`, which takes what `home_owner_accepts` takes and a `click` at
exactly `home.admin_path`; every other home, a resumed owner's included, keeps the
admissions it had and drops the click, so the capability, the socket and the daemon
each refuse it alone. The admin socket takes `admin_accepts`: a `click` or a
`submit` beneath `admin.body_path` (`"0\t2\t1"`, the body of the centre) and
nothing else, a batch with one other event dropped whole. The paths the earlier
pull requests pinned have not moved, and `ui_socket_test` pins the two new ones
and the refusals around them.

**Left out.** The sign-in rows, their revoke and the logins count (the browser
login's). The domain scope of each session, which the catalogue does not hold
(the service that does is not read from a page); the invitation control's
`NotIsolated` refusal says it in words when it matters. The reads
`memberships(p)`, which `members(s)` makes redundant for this page. Only the first
listing page of principals and of a session's members is drawn, and the page says
so and names `loom access` when there are more. A "Home" button on the admin
page: a ticket minted from it carries its deadline, so the home it opens would end
with the admin page, and one minted without would let a stolen admin page mint a
fresh admin page again, which the fifteen minutes exist to prevent; the owner runs
`loom ui` for another home.

**What a stolen admin page is worth.** As the design note's section 4.3 says, and no
more: inside its fifteen minutes it can revoke every member, credential and
membership, read the principal list and mint three claims or raised roles an hour
for the credential, each a membership that outlives the page until revoked. It
cannot reach the owner token or the root key, change who the owner is, grant
Owner or open a second admin page, since only a fresh home mints one and a ticket
minted from the page itself is not on offer.

**Cost.** One control command and one query, one scope and three routes, one
allowance table shared rather than added, one admitted path on the home and one
region on a socket, seven view modules and a component, and the loss of a way
back to the home from the admin page.

## Addendum: the browser login, the eighth pull request (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it. It builds the design note's
PR 8 and the login security review's decisions above. It adds the routes the
proposal lists, two control commands and one catalogue version, and it changes a
few things the proposal said, each named below. The admin page and its Admin
button are PR 5's and are not in it.

**What it builds.** `host/login` (the token's grammar, the HMAC chain, the
intersection, the root key's file); `client/daemon/ui_login` (issue, resume, the
start-time rule); the login cookie and nonce on a remembered exchange, in the one
function that builds a redeemed ticket's response (`server.entered`); `GET` and
`POST /ui/l/<key>/home` and the resume page; `Grant.origin` and
`Grant.remember`; `ui.link`'s `remember` and `loom ui --no-remember`; the home's
sign-in rows with "this browser" marked, "Sign out", "Sign out everywhere" and, on
a fresh home, "Sign in another device"; `credentials.signins` and
`credentials.revoke_login` with `loom access signins` and `revoke-login`; the
`logins` count on `principals.list`; the `daemon.login_issued`,
`login_resumed`, `login_revoked` and `logins_revoked` lines; and `loom --token`
refusing `loomb1:`. Nothing else is admitted on any socket: the home's socket
takes clicks beneath one more region, `home.signins_path`, and the forms'
submit admission is unchanged.

**What it changes in what the proposal said.**

- **The kind travels with the digest.** The proposal and PR 7 gave
  `authenticate` and `claim` a `CredentialKind` argument, fixed to `Bearer` in the
  manager. A page minted from a login re-authenticates on every frame through some
  fifty calls between the page and the catalogue, each of which would have needed
  the argument. `access.Digest` now carries its kind: `credential_digest`, which
  every wire path uses, makes a `Bearer`, and only `browser_digest` makes a
  `Browser`, so a string a connection presents can never be looked up as a login
  whatever it hashes to, and no caller can pick a kind apart from the digest it
  holds. The two arguments are gone. The paths that enroll a member's own
  credential refuse a `Browser` digest.
- **`bind` counts both kinds.** PR 7 left a note that `claim`'s
  no-active-credential check counted bearers only. 053's rule 3 says a member has
  an open claim and no credential, and a login is a credential, so the check now
  counts a row of either kind: a member whose only credential is a login binds no
  claim of either kind. `ActiveMemberCredentials` therefore loses the `kind =
  'bearer'` the proposal gave it, and its one caller is that check. The listing's
  `PrincipalActiveCredential` keeps it, so `principals.list` still reports the
  bearer or the claim and a login is counted beside it as `logins`; a member
  whose only credential is a login lists `credential: none` or `claim_open` and
  `logins: 1`.
- **Catalogue version 7** adds two nullable columns, `expires_at_ms` and
  `issued_by`. The listing has to be exact for a login that inherited an earlier
  expiry, and a family has to be traceable from any member, so both are stored
  (`issued_at_ms` and `last_resumed_ms` were already there). A login row without
  an expiry (a claim bound as a login, which PR 9 builds) is listed as live.
- **The origin is on the grant, not in the scope.** The proposal wrote
  `Home(origin)`; the design note's PR 8 paragraph names `Grant.origin`. A session
  page must carry the origin of the home it came from to the tickets it mints, so
  it is a field of `Grant` and `Scope` is unchanged. A ticket a page mints carries
  the page's origin, so a chain home, session, home from a resumed home stays
  resumed and one from a fresh home stays fresh. The design note's sentence that a
  home reached through a chain of switches is never fresh reads as 065's: the
  chain carries the origin of the page it began from.
- **The login travels with the ticket.** Every ticket carries the login of the
  context that minted it and a page keeps the login it is the browser of
  (`ui_sessions.Issuer`: fingerprint, expiry and the bookmark's key, never a token
  or a nonce). That is how a device link inherits the issuing login's expiry
  without the browser saying what it is, how the home marks "this browser", and
  why a chain of switches cannot launder a login into a fresh thirty days. A
  remembered exchange's page gets its login attached once the login's row is
  written (`attach_login`), and only once.
- **The cookie's `Max-Age` is the time left.** It is the token's expiry minus now,
  not always thirty days, since a device link's login ends when its parent does.
  The page's cookie is set first and the login's second, so a reader of the first
  `Set-Cookie` still finds the page cookie.
- **The root key is hex text.** `atomic_write_private` takes text, so `browser.key`
  is 64 lowercase hex characters, as `owner.token` is; the 32 bytes are what it
  decodes to, and a file of another length or alphabet is refused. The key is read
  back through `read_private_bounded` after it is written. A missing file revokes
  every `browser` row first and writes the key second (`probe_root`, then
  `write_root`), so a start that stops between the two finds no file again and
  revokes nothing more. A start with no `--ui` never reads or writes it.
- **A login narrowed to a session mints that session's page.** A token carrying
  `s` is not refused at the resume; it mints a `Session` page of that session with
  the reach of a link for one session (`OneSession`) and never a home. Nothing in
  this change makes such a token.
- **Every refusal of a login is one `401`.** The resume's pre-checks (the sender,
  the form's declared size and type, a daemon that is not serving, a body that is
  not a nonce) are `403`, `400` and `503`; every failure of the login itself is the
  same `401` document with a command to sign in again, no cookie and nothing
  echoed.
- **The bookmark is drawn as text.** A page opened by a remembered login shows the
  bookmark address, so the person can keep it; the daemon's address is the request's
  validated `Host`.
- **`__Host-loom_login` is not built.** It belongs to 052, which is not built.

**The callers of the two queries, and what each does with a browser-only
principal.** `principal_active_credential` has one caller,
`access.credential_summary`, behind `principals_page`, `manager.principal_page`
and the owner's `principals.list`: it returns no row for a principal whose only
active credential is a login, so the listing falls through to the open claim, or
to `none`, and reports the login in `logins`. `active_member_credentials` has one
caller, `access.no_active_credential`, run only by `access.bind` for `claim`, whose
callers are the `/v2/claim` socket (a `Bearer` digest) and, in PR 9, the browser
claim: it now returns the login's row, so the claim is `ConflictingClaim`, binds
nothing and stays open. `revoke_member_credentials` (rotation and revocation) and
the digest-reuse checks already ask both kinds, and are unchanged.

**A device link always sets a login.** An exchange whose ticket was minted under
a login (a device link) that cannot set its own, because the parent's time has
run out or the row is refused, is refused with the fixed `401` and opens no
page. Opening it without one would leave a page with no login and no parent, and
its own device link would then be thirty fresh days past the family's end. The
only `issue` caller is `server.remembered`, so this is the one place the rule is
held; a ticket with no issuing login (a person's own `loom ui`) still opens a
page without one when the daemon cannot set it.

A device link's exchange page runs under the issuing page's credential, so
revoking the child login does not end that page before its eight hours; "the
pages a login minted" means the pages its bookmark resumed.

**What a stolen page is worth.** A stolen fresh home mints a device link, which
the thief redeems into a login at the page's ceiling for the time the issuing
login has left, three an hour under the allowance, each listed with its parent;
that is the price 065's review named. A stolen resumed home mints nothing that
outlives its eight hours. A stolen cookie alone resumes nothing: the nonce is in
`localStorage` and is posted by the daemon's own page. A stolen root key signs a
login for any principal, which is why it is one `0600` file masked from every
session's jail (`serve.state_root_mask_candidates`).

**What it costs.** One more kind on every credential lookup, now carried by the
digest; a second cookie on a remembered exchange; a root key file and a start-time
rule for it; two columns; one region on the home and one more admitted click path
on its socket; and a registry call for each sign-in read, made with the sessions'
at the list's interval.

**Left for PR 9.** `claim` bound as a login writes `issued_at_ms` and no expiry;
the browser claim must record the login's expiry as `issue_login` does, and set its
login through `server.entered`.

**The admin page's part, built after the fifth pull request merged.** The owner's
Admin button and `admin_ticket_for` read the origin through one function,
`ui_socket.fresh_home(reach, origin)`, which now refuses a `Resumed` home as it
refuses a one-session page, so a resumed home is handed no button and a forged
press from one is `NoAdmin`. `Exchange` gained `AdminExchange`, and the ticket an
admin press mints carries the pressing page's login, so the admin page marks
"This browser". The admin page lists, beneath each principal that holds any, its
sign-ins (`grants.Logins`: the count, and the first ten, for at most twenty
principals a read), in the home's own words, each with a two-step "Revoke
sign-in" (`grants.RevokeSignin`). The daemon makes that change as every admin
change is made, afresh at the click (`administering`, then
`manager.revoke_login` under the owner's credential and the epoch), and it costs
no allowance. A fingerprint that does not belong to the named principal is
`NotFound`, and ending a login ends every page it minted at their next frame.

**Mutations, each applied alone and reverted, each failing the test it names.**

| Mutation | Failing test |
|---|---|
| the chain compared with `==` | `host/login_test.no_secret_is_compared_with_equality_test` (reads the module's source, since `==` gives the same answer) |
| a resume sets a fresh login, so a used login renews itself | `ui_route_test.the_bookmark_resumes_a_home_without_loom_test` |
| a repeated `c` taking the larger | `host/login_test.a_repeated_ceiling_narrows_in_either_order_test` |
| the row looked up before the chain is verified | `ui_route_test.every_token_that_does_not_open_is_refused_alike_test` (the registry's reductions move for a forged token) |
| the page cookie given a `Max-Age` | `ui_route_test.a_remembered_exchange_sets_the_login_beside_the_page_test` |
| a `Resumed` home offered the device-link control (the Admin button is PR 5's) | `ui_route_test.a_resumed_home_makes_no_device_link_test` |
| a device link minted from a `Resumed` home | `ui_route_test.a_resumed_home_makes_no_device_link_test` |
| a device-link login given thirty days under an issuing login | `ui_route_test.a_login_inherits_its_parents_expiry_and_a_dead_parent_makes_none_test` |
| `reserve_invite` skipped for a device link | `ui_route_test.a_fresh_home_signs_in_another_device_for_the_time_the_login_has_left_test` |
| a missing root key drawn without the revocation | `ui_route_test.the_root_key_cases_at_start_test` |
| only the first `loom_login` value read | `ui_route_test.a_planted_login_cookie_does_not_deny_the_real_one_test` |
| the resume document served with `form-action 'none'` | `ui_route_test.the_bookmark_resumes_a_home_without_loom_test` |
| a switch ticket minted `Remembered` | `ui_route_test.session_links_and_switch_tickets_set_no_login_test` |
| the kind dropped from the `authenticate` query | `storage/access_test.a_credential_authenticates_only_as_the_kind_it_was_made_as_test` |
| `ParentEnded` (and any failed issue under a parent) mapped to no login, so a device link opens a page without one | `ui_route_test.a_device_link_from_an_ended_login_opens_no_page_test` |
| `fresh_home` ignoring the origin, so a `Resumed` home is offered the Admin button | `ui_route_test.a_resumed_home_is_offered_no_admin_page_test` and `ui_socket_test.the_freshness_of_a_home_is_one_function_test` |
| the 64-hex shape check removed from `credential` | `daemon_server_test.a_bearer_that_is_not_64_lowercase_hex_is_refused_before_any_lookup_test` |
| `principal_active_credential` without its kind | `storage/access_test.a_login_is_counted_beside_the_bearer_and_never_in_its_place_test` |
| `bind`'s check counting bearers only | `storage/access_test.a_browser_row_blocks_a_claim_of_either_kind_test` |

Each was applied alone to the source, run against its named test until the test
failed on its own assertion (a compile error was not counted), and reverted.

**Tests.** `host/login_test` (the chain, the grammar, every refusal, the
intersection, appending, the three root-key cases); `storage/access_test` and
`catalogue_test` (the rows and their queries, the version 7 migration, the
claim's both-kinds rule); `ui_sessions_test` (the device ticket's lifetime, a
ticket's login, attaching once, the page cap across origins); `ui_http_test`
(the routes, the cookies, the declared form, the posted nonce, the policy);
`ui_route_test` (the exchange's cookies and nonce, `--no-remember`, the
bookmark, every refusal, a planted cookie, narrowing, revocation by login,
principal and rotation, no login on a `/v2` route, the device link in each
origin, the page's sign-in asks, a chain's origin and login, the scan of the
state root and the log, and the root key's start cases); `signins_test` and
`page_test` in `web_view`; `copy_test` in `web_client`; the access, view and
protocol tests in `host` and `tui`.

## Addendum: the browser claim, the ninth pull request (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it. It builds the design note's
PR 9: an invitee with no `loom` redeems a claim in a browser, chooses a name and
lands on a home with a login set. It adds two routes, one catalogue function and
one manager command, and no catalogue version. It also closes the item PR 8 left
for it and three review items PR 8 left in the same code.

**What it builds.** `GET /ui/claim`, a fixed form (`page.claim_page`: a token
field, an optional name field and the words that say the inviter's name is kept
when it is left empty), served under `form-action 'self'`; `POST /ui/claim`
(`server.claim_submit`); `ui_login.claim`; `manager.claim_login` and
`access.claim_login`; and the notices a refusal is drawn with
(`page.ClaimNotice`). Nothing is admitted on any socket, and the home the claim
opens is the home PR 8 built.

**What the route does, in order.** The host is checked by the router. The sender
must be this origin's own page: `Sec-Fetch-Site` is `same-origin` and nothing
else (`ui_http.same_origin_post`, PR 8's rule). The form is declared at most 1
KiB, URL-encoded, with no transfer encoding. The body is read and must be
`token` and, optionally, `name`, each once and no other field. The token is
trimmed of the spaces a paste carries and must then be `loomclaim_` and 64
lowercase hex characters, and this is checked **before any lookup and before any
permit**, so a bearer, a login, the owner's credential, a capitalised or
truncated claim or an empty field is refused with the registry having done no
work and the daemon no place taken. Only then is the claim hashed, dropped and
reserved (`root.acquire_claim`, one reservation per claim as `/v2/claim` takes
it, so a second post of a claim already in flight is `409` with the busy words,
and a daemon that is not admitting is `503`), and redeemed. The browser claim
therefore takes no control-class permit; the route table's earlier line that it
did is superseded.

**What the redemption is.** `ui_login.claim` draws a login (identifier, key,
nonce) and calls `manager.claim_login`, which runs `access.claim_login`: the same
transaction as `claim` (every check before every write, the name judged before
the first write, so a refused name binds nothing and the claim stays open), with
the credential it binds a `Browser` row written as `issue_login` writes one, with
`issued_at_ms` and an expiry. The expiry is `login.lifetime_ms` (thirty days) from
the claim, closing PR 8's note that a claim bound as a login recorded none. The
token is signed **after** the transaction, since the claim is what names the
principal; so no refusal has a token or a nonce to leak. The login is an
`Operator` login, as the design note says, and `Operator` caps a membership and
never grants one.

`claim` takes a `Bearer` digest only, and `claim_login` a `Browser` one, each
refusing the other kind. The expiry is part of the login's variant inside
`storage/access` (`Presented`), so there is no way to bind a claim as a login
without one. `InsertAccessClaimedLogin`, which wrote none, is removed in favour of
`InsertAccessLogin`.

**The login is set through the one place a login is set.** `server.entered` split
in two: it still decides whether the exchange's ticket asks for a login and
issues it, and the half that writes the response, `enter_response`, takes the
login to set. The claim does not go through `remembered`, because its login was
bound by the claim and writing a second row would be a second login for one
claim; it reaches `enter_response` with the one it bound, after minting and
redeeming a `Home` ticket (`Fresh`, `Operator`, `Workspace`, `Forgotten`) in the
same request and attaching the login to the page. The response is the exchange
page with the page cookie and the login cookie (its `Max-Age` the time left) and
the login's key and nonce in the body, as a remembered exchange's. A `Forgotten`
ticket is right here: it asks for no login of its own, and the home it opens is
the browser of the login the claim made.

**Refusals, in fixed words.** A refusal a person can correct is the claim form
again, under `form-action 'self'`, with one fixed paragraph over it and no cookie.
The words are the same for the same reason whoever asks and none repeats anything
the request carried:

| Reason | Status | Words begin |
|---|---|---|
| not a claim token (any other shape) | 400 | That is not a claim token. |
| unknown, or voided by a rotation | 404 | This claim is not valid. |
| expired | 410 | This claim has expired. |
| spent, bound to another credential, or its member already holds one | 409 | This claim has already been used. |
| a name that is blank, over 256 bytes or holds a control character | 400 | That name cannot be used. |
| the registry could not answer | 503 | The daemon could not take the claim just now. |

A cross-site, same-site, `none` or header-less `POST`, a host that is not
loopback, a body that is not the declared small form, and a daemon that is not
serving are `403`, `403`, `400` and `503` plain documents with no form, and none of
them touches the claim. The success carries the policy every document has,
`form-action 'none'`; only the form and its refusals carry `'self'`.

**What it changes in what the proposal and the design note said.**

- **`POST /ui/claim` is `same-origin` only.** The route table said `none` or
  `same-origin`, which `none` makes a post nobody can type. The claim holds the
  same rule as the resume (PR 8): the one thing the browser sends is a form this
  origin served.
- **The listing shows the claim redeemed.** A login that a claim bound is the
  credential that claim made, since the browser claim has no bearer.
  `principal_active_credential` lists a `browser` row only when an `access_claims`
  row names it, so `principals.list` and `loom access list` show
  `credential: active` with the fingerprint and `claimed_at_ms`, and the same
  login is counted in `logins` as every login is. A login no claim bound is
  counted only, as PR 8 said. Rotation and revocation end both together.
- **The name is the catalogue's.** The form sends the name as typed. An empty
  field is no name, so the inviter's name stays; a field of spaces is a blank
  name and is refused `NameRefused` with the claim open. The catalogue trims and
  judges it, as for `loom claim --name`.
- **A lost reply is not replayable.** The login's identifier is drawn per
  request and a replay would draw another, which a claim bound to the first
  refuses as `ClaimedBy` another credential. A person whose response was lost
  after the bind (the connection dropped, the page closed before the script ran)
  has a spent claim and a login nobody holds; the owner rotates, which voids it
  and issues a new claim. `/v2/claim` can replay because its credential is the
  client's own digest; here there is nothing the client holds to present twice.
  Making this recoverable would mean the browser choosing the login's identifier
  and presenting it twice, which would put a value the daemon must trust into the
  claim's body for the sake of a rare lost response.

**The three PR 8 review items.**

- **A ticket whose login has ended is refused before it takes a place.** In
  `ui_sessions` `Redeem`, a ticket that sets a login (`Remembered`) and carries
  `Some(issuer)` with `issuer.expires_at_ms <= wall` is `UnknownTicket` before
  `with_room` runs, so a device link opened after its family ended neither takes a
  page's slot nor evicts the owner's oldest home. A `Forgotten` ticket (a switch,
  the way home, an admin press) also carries the page's login but sets none, and
  its page keeps working to its own deadline, so it is not held to the login's
  end; a first draft refused those too, which would have stopped a resumed home
  from switching after its login's last day. `server.entered`'s `401` for a login whose row
  is refused stays. The table's `now` is the monotonic clock and an issuer's
  expiry is a wall-clock instant, so the comparison needed the wall clock:
  `Settings` gains `wall` (`bootstrap.system_time_ms` in production), the one
  field this change adds to an existing record.
- **`server.resume_exchange` has no `Admin` arm.** The scope, the reach, the
  exchange and the page's address are built in one `case` on the login's session,
  so a scope that cannot be reached is not written down.
- **`ui_socket.admin_standing` says why `Fresh` is sound**: `admin_ticket_for` mints
  an admin ticket only from a `Fresh` home (`fresh_home`) and the admin socket
  mints no tickets.

**What a stolen claim is worth.** A claim string in a chat log is, until it is
redeemed, the credential for one browser's thirty days at `Operator` ceiling on
whatever the member holds, which is 053's rule and the reason a claim lives an
hour by default and is single use. Redeemed by the wrong person it shows in
`principals.list` as `claimed_at_ms` and as a login the owner did not expect; the
owner rotates, which ends that login. Nothing but the digest of the claim, and the
digest of the login's identifier, is under the state root, and no log line holds a
claim, a login or a nonce.

**What it costs.** Two routes and a form document; a second public claim
function and a manager command; a field on `Settings`; a split in `entered`; one
more place a person's typed value is read (bounded to 1 KiB and checked for shape
before anything else). A claim redeemed in a browser has a thirty-day login and no
bearer: the invitee cannot use `loom` or the terminal's `/v2` from it, and
`loom claim` is still the route for that.

**Mutations, each applied alone and reverted, each failing the test it names.**

| Mutation | Failing test |
|---|---|
| the token's shape check removed, so any value is hashed and looked up | `ui_route_test.a_cross_site_claim_and_a_value_that_is_no_claim_ask_nothing_test` (the registry's reductions move) |
| the sender check taken from `navigation_allowed`, so `none` posts | `ui_route_test.a_cross_site_claim_and_a_value_that_is_no_claim_ask_nothing_test` |
| the login row bound without its expiry | `ui_route_test.a_browser_claim_lands_on_an_operator_fresh_home_with_a_login_test` and three others |
| the ended-login arm of `Redeem` made unreachable | `ui_sessions_test.a_ticket_of_an_ended_login_evicts_no_page_test` |
| a refusal of a claim served under `form-action 'none'` | `ui_route_test.a_claim_that_cannot_redeem_is_refused_in_fixed_words_test` |
| `Settings.wall` in `production` made the monotonic `now` | `ui_sessions_test.the_production_table_judges_a_login_by_the_system_clock_test` |
| the ended-login guard compared with `now` and not `wall` | `ui_sessions_test.a_ticket_of_an_ended_login_evicts_no_page_test` (the test table's wall is a long way from its `now`) |
| the ended-login guard applied to a `Forgotten` ticket | `ui_sessions_test.a_switch_ticket_of_an_ended_login_still_redeems_test` |
| the claim's home minted `Resumed` | `ui_route_test.a_browser_claim_lands_on_an_operator_fresh_home_with_a_login_test` |

**Tests.** `ui_route_test` (the form, the redemption and its listing and its
bookmark, every refusal and the name that binds nothing, the senders and the sizes
and the values that are no claim, the state-root and log scan that reaches the
catalogue), `page_test` (the fixed form and its words, each notice, the policy),
`ui_http_test` (the routes and the posted fields), `ui_sessions_test` (the ended
login's ticket and the pages that survive it), `storage/access_test` (a claim
bound as a login ends at its expiry and is listed as the credential, each kind
refused by the other's function).

## Addendum: the admin page's placements and the scope on `sessions.members` (2026-10-04)

**Status**: IMPLEMENTED in the change that adds it (round 4 of the web UI
critique, findings F78 and F82 to F89). It changes where the admin page draws
and says things, and adds one field to one owner-only read.

**`scope` on `sessions.members`.** The reply body gains `scope`, `"session_only"`
or `"workspace_private"`, the scope the session's domain record holds. It is
additive: an existing client ignores a field it does not know, and `loom access
members` does not print it (`host/access.member_lines` reads `members` and `next`
only). The read stays owner-only, refused `forbidden` for a member before any
parameter is judged, and the field is the same fact `sessions.get` already
reports as `domain_scope` to the same owner. The registry reads it with the
session's members in one call (`manager.session_member_page` answers a
`Members(scope, page)`), so the page learns it before the owner presses
anything. The admin page draws no invitation form for a private session and says
why in one sentence, where it drew a form that could only be refused with
`NotIsolated`; this closes the item the admin addendum left out ("the domain scope
of each session, which the catalogue does not hold"), because the registry does.

**What else moves, with no wire change.** The claim an invitation or a rotation
makes is drawn beside the action that made it, not pinned over the page. It
leads with the browser claim address (`http://` and the host the page was reached
at, `/ui/claim`), then the token, then the `loom claim` command for a person who
has `loom`; the address is a fixed shape the copy box admits and holds no secret.
A principal with an open claim is one row of the People list with a `Void
invitation` button, not a second list. The refusal of a fourth grant in an hour
names the count and the UTC time a place frees: `reserve_invite` answers the
wall-clock instant, which is an in-daemon value and reaches the page only as that
sentence. The allowance itself, three an hour for one credential across this page,
a session page's invitation control and a device link, is unchanged by the
owner's ruling. A change's notice is a line under the section acted on and a
refusal stays beside its control (`view/notice`). `admin.body_path` and every
other pinned path are where they were: the centre's first child is now an empty
place, so the body is still its second child.

**Cost.** One additive field and the manager call that carries it; a second
subject in `<loom-copy>`; no catalogue version, route or admitted event.

**Tests.** `daemon_access_test` (the `scope` of a members reply), `ui_route_test`
(the admin read's scope for a shared and a private session, the claim address in
both claims, the refusal's count and instant), `ui_sessions_test` (the instant a
place frees, in wall terms), `admin_test` (one row for each principal, the claim's
position, no form on a private selection, the notice's placement, the token in
one patch and no other), `grants_test` (the refusal's words), `copy_test` (the
claim address's shape), and `scripts/web_client_css_check.sh` (nothing under
`.admin-body` is `position:sticky`).

## Addendum: session actions on the home and the admin page's lifetime pill (2026-10-05)

**Status**: IMPLEMENTED in the change that adds it (round 4 of the web UI
critique, section 5 item 3 and finding F87). It adds one daemon capability to the
owner's fresh home and one in-daemon value to the admin page. It adds no route,
no admitted event and no field on the wire.

**The problem.** The daemon stops, archives and deletes sessions for a terminal
(`sessions.stop`, `sessions.archive`, `sessions.delete`), and the home, which
lists every session, offered none of them. An owner who wanted a session gone had
to leave the page.

**What changed.**

- **A row's quiet buttons.** On the owner's fresh home, a running row has `Stop`
  and a saved row has `Archive` and `Delete`, beside `Rename`, in one group after
  the row's own button (`view/home_table`, `web_view/actions`). A running row
  offers no archive or delete, because the registry refuses both for a session a
  process holds (`AdminBusy`), and a saved row offers no stop.
- **Delete is two presses.** Delete replaces the row's words with `Delete this
  session? This cannot be undone.` and a Delete and a Cancel, in the row, as the
  rename form is drawn. The daemon takes no such step: the confirmation is the
  page's, and the daemon's checks are the same for a confirmed press and a
  forged one. Stop and Archive ask at once; an archive is undone from a terminal
  (`sessions.restore`) and a stop leaves the session on disk.
- **The daemon decides each press.** `Start.manage` is `Some` only for the
  owner's page minted to operate and opened by a `loom ui` exchange
  (`ui_socket.home_manage_capability`, which judges `fresh_home` as the Admin
  button does), so a home a bookmark resumed, a member's home and a read-only
  link draw nothing and ignore the messages. `ui_socket.manage_for` re-derives
  all of it when the press arrives: the page is still open and fresh
  (`fresh_home`, `owner_operating`), its credential still authenticates as the
  owner, and the target is a canonical session identity. A stop is
  `manager.stop_session`, the call the control command makes, followed by a
  bounded wait (`stop_wait_ms`, five seconds, as a `weft/poll` loop) for the
  registry to hold the session saved, so the page's next read does not list it as
  running. An archive is `manager.set_visibility` and a delete is
  `manager.delete_session`, which authenticate the credential and the epoch again
  in the registry's own turn.
- **The runtime never waits.** The request is a weft task (`manage_task`), as the
  rename and the resume are; its answer is a message (`ActionAnswered`) and the
  page reads its list again.
- **A refusal is fixed words.** `NotOwner` covers every standing the page cannot
  claim and an identity the catalogue does not hold, `Running` is the one
  actionable reason (`That session is still running. Stop it first.`), and
  `Unavailable` covers the rest. No text the daemon or the catalogue wrote
  reaches a browser.
- **No new admission.** A row's buttons are clicks beneath `home.table_path`,
  which every home's socket already admits for a row. The capability decides
  whether a button exists and whether the component acts on a press. No pinned
  path moved: the buttons are a group after the row's own button, and
  `home.table_path` and `home.admin_path` are as they were.
- **`HomeAttachment` gains `sessions_directory`**, the daemon's own directory a
  delete removes the database family from. No page supplies it.
- **The admin page's lifetime is a pill.** `admin.Start` gains `ends_at`, the
  instant the page ends, read once when the socket opens from the live UI
  session's deadline (the earlier of the home's end and fifteen minutes after the
  exchange) and carried from the table's monotonic clock to the wall clock the
  page counts in. The bar shows `ends in 14m` as a quiet pill, the figure drawn
  by `<loom-elapsed remaining="...">`, which counts the milliseconds down in the
  browser and anchors again on each new figure. The body's sentence about the
  page's lifetime is gone; the pill's `title` says to press Admin on the home for
  another page.

**What was considered.**

- *A browser `confirm()` for Delete.* It is not part of the page's design and
  cannot be tested without a browser; the row's second step is.
- *Letting a Delete stop the session first, as the terminal does.* The terminal
  waits for the stop to drain before it asks for the delete. The page's Delete is
  offered only on a saved row, so the case never arises on a page that is current,
  and a page that is stale is refused with `Running` rather than the page
  stopping a session the owner did not ask it to stop.
- *Offering the actions on every owner home.* A bookmark is a long-lived
  credential, and the admin page already refuses it for the same reason: an
  action that removes a session's history should not be reachable from a link
  that was saved for convenience.

**Cost.** One capability and one task on the home, one field on the home
attachment and one on the admin page's start, and a second attribute on
`<loom-elapsed>`. A drain that outlasts the stop's five seconds answers as a stop
that was made and shows the session as running until the page's next read.

**Tests.** `home_test` (the buttons that fit each row, the confirmation, one ask
for each press, the fixed words, a page with no capability, the paths),
`ui_socket_test` (the capability and that no admission is added),
`ui_route_test` (each action against a real registry, every refusal, and the
task), `admin_test` (the pill and the missing sentence), and `elapsed_test` (the
countdown's words).

## Addendum: renaming, the tenth pull request (2026-10-05)

**Status**: IMPLEMENTED in the change that adds it. It builds the control command
this document proposed last and optional, and the two web surfaces the design note
names for it. It adds one control command, one event the home's socket admits and
no catalogue version: `storage/access.rename` already existed, with the claim's own
name rule, and had no caller.

**The command.** `principals.rename` is as the proposal wrote it, with these
details. `principal_id` is optional and `name` and `epoch` are required. A member
omits `principal_id` and renames itself, and naming itself is the same; a member
naming another principal is `forbidden`. The owner may name any principal and
itself. The registry reauthenticates the caller and the epoch in the dispatch that
writes (`manager.rename_principal`), drops its authority memo before it answers, and
refuses during a drain, so it is `ControlMutation`. The name is the unjudged text
on the wire (up to 1024 bytes, blank included, so the catalogue is the one judge),
trimmed and then held to the rule a claim's chosen name is held to,
`storage/access.new_name`, in the same function that renames: not blank, at most
256 bytes, no control, zero-width or direction-changing character. A name that rule
refuses is `invalid_name`, the code a refused claim name already uses, and stores
nothing. An unknown principal is `not_found`, a stale epoch `stale_epoch`, a
malformed frame `bad_request`. The reply names the principal and the name as
stored. Origins already admitted keep the name they were admitted under
(`core/message.gleam`); a page or a session admitted afterwards reads the new one.
There is no `loom access rename` in this change.

**On the home.** The person's name in the bar opens the account panel (the first
pull request's popover), and the panel gains a "Your name" region as its first
child: a lead that shows the current name as a text node, a text field in a
`<loom-rename>` that copies the lead's text into it in the browser, and one submit
button. The name is never an attribute, and the form is keyed by how many times the
name changed so a stored name opens a fresh form on it. `Start.rename_self` is `Some`
for a page minted to operate, whoever its principal is, and `None` for a read-only
link, which draws nothing in its place. A home a bookmark resumed may rename its
principal, as it may end that principal's logins: the rename mints nothing, which
is the line a bookmark may not cross (a device link and the admin page both mint).
The daemon decides again at the submit
(`ui_socket.rename_self_for`): the page is open, its ceiling is Operator, the
credential authenticates as the principal the page was admitted for, and the
registry's own turn applies the rule above to that principal and no other, so the
page names nobody. The work runs as a weft task (`rename_self_task`); the page's
runtime never waits. A refusal is the fixed words of `web_view/names`. Every list
the home reads also reads the principal's name (`Start.who`), so a name the owner
changed from the admin page reaches an open home at its next read.

**On the admin page.** Every person's row, the owner's included, has a Rename
button that opens a small form in that row, in the words and the shape of the
home's session rename. Its submit is the seventh change the page may ask for
(`grants.Rename`), made by `ui_socket.rename_for_admin` after the checks every change
begins with. It grants nothing and costs none of the credential's allowance.
`invalid_name` is `grants.InvalidName` and an unknown principal `grants.NotFound`.

**The admission.** The one new event the home's socket takes is a `submit` beneath
`home.signins_path` (`0\t2\t2\t...`), where the form is. It is admitted for every
home, since a member's home has no other submit; a home that draws no form has no
handler there, and the daemon refuses the request from any page that holds no
capability. The panel's own path, a sibling that shares its digits and every other
event stay dropped, and a batch with one such message is dropped whole. The table's
forms are still admitted only for the owner's operating home, and the admin
socket's admission is unchanged because the admin form is beneath
`admin.body_path`. 051's addendum on the home's name form records the admission in
that document's format.

**What was considered.**

- **A click that reads the field.** A button whose click event carried the field's
  value would need a property on every click the server component forwards, which
  the closed message type avoids. A form's `formData` is the shape the other forms
  already use.
- **A second validator.** The daemon's `catalogue.display_name` is the same rule as
  the claim's, but a function that renames should not rely on a caller judging first.
  The registry's rename is the only judge, and the page's `invalid_name` is that
  function's refusal mapped, not a parallel check.
- **A schema bump.** Nothing is stored beyond the existing `display_name` column.

**Cost.** One control command, one registry message, one admitted event and one
`Start` read per home refresh (`manager.authenticate`, a single indexed query).

**Tests.** `daemon_protocol_test` (the decoder and its refusals),
`ui_route_test` (who may name whom over the control socket, the claim rule's
refusals, a stale epoch, the home's and the admin page's daemon checks),
`ui_socket_test` (the admission and the capability), `names_test` and
`admin_test` (both forms, their paths and the refusals' words).

## Addendum: the admin page's polish, round 5 batch B20 (2026-10-05)

**Status**: IMPLEMENTED in the change that adds it (round 5 of the web UI
critique, findings F112, F116 and F118). It adds one in-daemon field to the admin
page's snapshot and two client elements, and no frame, route, admitted event or
catalogue version.

**`summaries` on the admin snapshot.** `grants.Snapshot` gains `summaries`, one
`Summary(session, people, more, scope)` for each listed session the registry
answered for. The daemon reads each with the call that already reads the chosen
session's members and scope (`manager.session_member_page`, owner-only, refused
`forbidden` to anyone else), so the field is the same two facts `sessions.members`
already gives, made for every listed session instead of the chosen one. `people`
counts the owner, who holds no membership rows, and the members one listing page
holds, and `more` says whether that is all of them. A session the catalogue no
longer holds when the read reaches it has no summary and its row has no line. It is
an in-daemon value, not a wire frame: nothing a browser sends or receives
changes, the page's decoders have nothing new to decode, and `admin.body_path`
stays `"0\t2\t1"`.

**`<loom-time at=ms>`.** The refusal of a fourth grant in an hour used to say `The
next is free at 13:02 UTC.` The page now writes the instant as the element's `at`
attribute, a number the daemon made, and the browser draws it as the time of day in
its own zone. The UTC time stays as the element's `title` and its light text, which
a browser without the element still shows. The server never guesses a zone. The
words around the time are the same fixed words.

**`<loom-reveal>`.** An empty element, the first child of a claim's box, that
scrolls its nearest `section` into view by the least that shows it, once, when it
is inserted. The claim stays a single patch (`admin_test` pins that), and a later
read that leaves the box in place scrolls nothing.

**What else moves, with no wire change.** The invitation form is keyed by the
count of invitations the page has made, so a made invitation opens a fresh form
with an empty name field. The claim box for an invitation no longer states a role,
since the member's row shows the current one.

**Cost.** One registry call for each listed session on each admin read, which is
the interval's thirty seconds and each press; a read is one indexed query and the
list is at most `sessions.listed_limit`.

**Tests.** `admin_test` (the summary line, the fresh form's path, the keys, the
box with no role and its reveal, the time element), `grants_test` (the halves of
the refusal), `time_test` in `web_client` (the zone arithmetic and the attribute's
shape).

## Addendum: the home's notes, a Stop that asks when busy, and the sign-in words (2026-10-05)

**Status**: IMPLEMENTED in the change that adds it (round 5 of the web UI
critique, batch B19, findings F101, F102, F108, F110, F111, F113 and F117). It
adds no route, no admitted event and no field on the wire. One part of F111, the
`read-only` label on a sign-in row, is not done, for the reason under *What was
considered*.

**The problem.** The home still drew a completed action as a full-width box above
the list that moved the list and never went away, said `resident` beside every
row, acted on `Stop` at once for a session in the middle of a turn, gave no sign
that a pressed row was opening, said `not used yet` of the browser in use, and
said nothing about why a bookmark-resumed home has no Admin button or session
actions.

**What changed.**

- **Notes, not a notice.** What the page last said is a `home_table.Note`: a
  `view/notice` `Said` (quiet, fades after four seconds) or `Refused` (stays, in
  the danger colour), and where it goes. A note about a session is the last words
  of its row's quiet line; when the row is gone (an archived or deleted session)
  it is in the workspace's heading line and names the session (`docs sweep
  archived.`); a note for a refused creation is in the workspace's heading line;
  anything else is one line under the page's heading. Nothing takes room the list
  did not already have. The words are the page's fixed ones, and the session's name
  is a text node. The progress words (`Stopping the session.`, `Creating the
  session...`) are gone: the row's buttons or the form are disabled meanwhile.
- **Stop asks when the row is busy.** `StopRequested` opens the row's
  confirmation, in a neutral tint, when the page's own activity read
  (`Model.activity`) has the row as `working` or `needs you`, and acts at once
  otherwise. `actions.Stage.Confirming` carries the action, and there are two
  confirmations, `StopConfirmed` and `DeleteConfirmed`; each acts only for the
  row and the action that are confirming, so a forged confirmation for a row that
  is not in that state does nothing. The state is the server model's alone. The
  daemon's checks in `ui_socket.manage_for` are unchanged and are the same for a
  confirmed press and a forged one.
- **`Opening...`.** A pressed row, running or saved, shows a spinner where its
  chevron was, dims, and says `Opening...` in place of its words from the press
  until the page leaves (`Model.opening`, `Model.resuming`); a ticket does not
  clear them, only a refusal does, and a second press asks nothing.
- **Words.** `resident` is dropped beside an activity word (`idle`, `working`,
  `needs you`) and is `running` where no activity is known, on the home's rows and
  on a session page's sidebar. A sign-in row for the browser in use omits when it
  was last used; another row says when or `not used yet`; a login a device link
  made says `device link` in place of the issuing login's fingerprint. The create
  form's hint is hidden once the field holds a name.
- **The resumed home says why.** The owner's home that a bookmark resumed, which
  the page tells from the others by having `Start.rename` and no `Start.manage`,
  ends its sign-in region with `This page was opened from a bookmark. Run loom ui
  for a page that can manage sessions and people.` and a copy box for `loom ui`
  (`copy_rule.Link`). The rule that such a home has no Admin button, device link or
  session actions stands.

**What was considered.**

- **A `ceiling` field on the sign-in listing.** The critique asked for a
  `read-only` label on a row whose login was made by `loom ui --observe`, as one
  additive field on the listing. A login's ceiling is a caveat in the token the
  browser holds (`host/login.gleam`); the catalogue row has no ceiling and the
  daemon keeps no copy of a token. The field would need a new column on
  `access_credentials`, a catalogue migration and a change to `issue_login`, which
  is storage work and not an additive field on a read. It is not done here. The
  home's own read-only state is already drawn as the bar's `read-only link` pill.
- **Confirming a stop when the activity is unknown.** A row the read has not
  named yet is stopped at once. The ruling is that Stop asks on a working or
  needs-you row, and nothing says an unnamed row is either.
- **A timer to clear a note.** The fade is the stylesheet's, as the session
  page's footer is, so the server keeps no timer; the note leaves at the next
  press.

**Cost.** None on the wire. The home keeps one note and one opening session in
its model.

**Tests.** `home_test` (the busy and idle stops, the forged confirmations, a note
in its row and in the heading, a refusal beside its row, `Opening...` and the
ignored second press, `running` and the activity words, the resumed sentence),
`signins_test` (the use clause, the device-link words), `sidebar_test`, and
`admin_test` (the shared sign-in words).

## Addendum: making a session shareable (2026-10-05)

**Status**: IMPLEMENTED in the change that adds it (round 3's F55, round 4's F88,
round 5's F100 and its section 5, the top missing feature). It adds no route, no
admitted event and no control command: the task is an ask the daemon runs in its
own process on behalf of a page, as 065's other asks are. It adds one `Action`,
`MakeShareable(session)`, to the admin page's component and one control to the
session page, and it says here which of the three registry operations it runs and
what each refusal leaves behind.

**The problem.** A session created `workspace_private` shares its workspace's notes
and history, so the registry refuses to give another person a seat in it
(`IsolationRequired`). The only way out was a terminal: stop the session, `loomd
access isolate SESSION --share-existing-transcript`, resume it. Both pages said
the session could not be shared and offered no button.

**What was built.** `client/daemon/shareable.make(registry, digest, epoch,
state_root, id)` runs the same three registry operations in the same order, and
nothing else:

1. The credential must authenticate as the daemon's owner. This check is made
   first because `manager.stop_session` takes no caller and a stop is the first
   change.
2. If the session is private, it is brought to rest: a resident session is
   stopped with `manager.stop_session` and waited for (`stop_wait_ms`, 15 s), a
   saved or already stopping one is only waited for. A session that is opening,
   reserved or blocked is refused before anything is done to it.
3. `manager.isolate`, the daemon's own isolation, the operation `sessions.isolate`
   runs. It authenticates the credential and the epoch a second time in the
   registry's turn, so it is the last word on who may.
4. A session that was running is resumed with `manager.open` and waited for
   (`resume_wait_ms`, 30 s). A session that was saved when the task began stays
   saved: the task puts back what it found.

A session that is already session-only has nothing to do, so the task is
idempotent. Isolation is one catalogue transaction (`storage/domain.isolate`), so
a session is private or session-only and never between.

**What each refusal leaves.** No refusal leaves a half-isolated session, and every
state a refusal leaves is one the owner leaves by pressing again or by resuming
from the home page, which the refusal's words say.

| refusal | where it stopped | the session is left | words |
| --- | --- | --- | --- |
| `NotOwner`, `NotFound`, `Unavailable` | before anything changed | exactly as it was | the page's existing words |
| `NotStopped` | the stop did not finish in 15 s, or the registry would not stop it | the stop was issued and still completes; private, and once saved a second press moves it and leaves it saved | `The session is still stopping, so it was not moved and is still private. Once it is saved, press again; it will be moved and left saved.` |
| `NotMoved` | isolation was refused (for example another page resumed the session in the meantime) | private, and running again when it ran before | `The session could not be made shareable and is still private. Try again.` |
| `Stranded` | isolation was refused and the session could not be resumed either | stopped and private | `The session could not be made shareable, and it is stopped. Resume it from the home page, then try again.` |
| `NotResumed` | isolation succeeded and the resume did not | stopped and shareable | `The session is shareable now but did not start again. Resume it from the home page.` |

`grants.Reason` gains `NotStopped`, `NotMoved`, `Stranded` and `NotResumed`, and
`grants.changed_words(MakeShareable(_))` is `This session is shareable now.`.

**A task no page owns.** Stopping a session ends every page open on it, and a
weft run linked to a page's runtime ends with the page. A task started the way
`resume_task` and `manage_task` start theirs would be cancelled between the stop
and the isolation, leaving the session stopped and private. `ui_socket.detached`
therefore runs the task in a plain `process.spawn_unlinked`. No weft shape fits:
every weft start links its scope to the process that calls it, and this run must
outlive the page the stop ends, so a weft wrapper would add nothing. The answer
goes to the page's runtime if it is still there. Every step is bounded by its own
call timeouts and by the 15 s stop wait and 30 s resume wait, so the worst case is
about 90 s, and a deadline would only kill a task that was about to answer. Every
manager call in the task is a `try_call` with a 5 s timeout and the process cannot
crash, so the answer always lands, and the admin page's `waiting` is cleared only
by that answer: a refresh that cleared it earlier would drop a `NotResumed`.

**Two presses at once.** Both stop the session, and the second isolation is
refused because the first one made the change. `shareable.make` re-reads the
session's scope when isolation is refused and takes the success arm when it is
already session-only, so neither press reports a failure to move.

**Authority.** Re-derived in the daemon, never read from a page.

- The admin page asks through `admin_for`, behind `administering` (the page is
  open, minted to operate, and its credential authenticates as the principal it
  was admitted for, who is the owner). The page is already the owner's.
- The session page's capability is `shareable_capability(role, origin, ask)`,
  `Some` for `Owning` on a page a `loom ui` exchange opened and `None` for
  `Operating`, `Observing` and any page a bookmark opened (`mints_access`).
  `shareable_for` checks again that the page's origin may mint access, that the
  page is open and that `role_of(attachment)` is `Owning`: a member operator, an
  owner's read-only page, a bookmark's page and a page that has ended are
  `NotOwner` whatever frame reached the daemon, and nothing is stopped. The event
  path is the invitation control's (`component.invite_path`), which the owner's
  socket alone admits (`owner_accepts`).
- `shareable.make` authenticates the owner a third time before the stop.

**A bookmark cannot mint access.** Making a session shareable and creating an
invitation both give other people a way in, so both are fresh-page only, like the
admin page and device links (the eighth pull request): a page a `loom ui`
exchange, a claim or a device link opened may, and a page a browser login's
bookmark opened, or one such a page's home opened, may not. This amends the
invitation control (051, the addendum on inviting from the session page), which
was offered to any owner's operator page. `invite_capability`,
`shareable_capability`, `invite_for` and `shareable_for` all take the page's
origin (`seen.grant.origin`) and refuse a `Resumed` one, with `NotOwner`. The
Session tab of such a page draws no button of either control and says `This page
was opened from a bookmark, so it cannot invite people or make a session
shareable. Run loom ui for a page that can.` (`invites.Bookmarked`, and
`BookmarkedPrivate`, which keeps the private session's own sentence), worded like
the resumed home's. `component.Standing.opening` carries which it is, read by
`ui_socket.standing_of` from the grant and never from the page.

A stolen operator-ceiling owner page from a fresh `loom ui` link can now stop one
of the owner's sessions and restart it under a new history, and so can invite, as
it already could invite. A bookmark's page can do neither, and a read-only page
cannot do either at all.

**Where the daemon's state root comes from.** The isolated session's fresh stores
are minted under the daemon's own state directory. `server.AdminAttachment` and
`server.Attachment` carry it (`state_root`), from `root.Ready`, and no page ever
supplies it. `ui_socket.admin_for` and `admin_task` take it as an argument.

**The pages.**

- *Admin page.* A private session's members block draws the sentence it already
  drew and, beneath it, `Make shareable`, for a session that is running or saved
  (a session the daemon will not open from a page is offered nothing, since the
  task would refuse it). The button is a two-press control: the first press
  (`Arming`) replaces it, in place, with `Make this session shareable? It will
  stop, move to its own history, and resume. People you invite will be able to read
  what it already holds.` (for a saved session: `It will move to its own history
  and stay saved.`), a `Make shareable` confirm and `Cancel`. The state is
  `Model.armed`, the server's alone. `Asking(MakeShareable(_))` is sent only when
  the same action is armed (`admin.confirmed`), so a frame that names the change
  without the question asks nothing. While the task runs the button is the
  sentence `Making this session shareable: stopping it, moving it to its own
  history and resuming it. This can take a minute.` and every button is disabled
  (`Model.waiting`). On success the next read finds a session-only session and the
  invitation form appears, with `This session is shareable now.` beside it. A
  refusal is drawn beside the control in its fixed words. All of it is beneath
  `admin.body_path`, which does not move.
- *Session page.* The Session tab's private sentence (`share.private_words`)
  gains the same button, in the same region, so `component.invite_path` is
  unchanged and holds one handler (the button), two while the question is open.
  The state is `shareables.Move` (`Withheld`, `Idle`, `Confirming`, `Making`,
  `Refused`) in `View.moving`, set only by `component.arm_shareable`,
  `disarm_shareable` and `make_shareable`, and `make_shareable` sends the task only
  from `Confirming` and with the capability. The words after the confirm say that
  the page ends while the session restarts.

**What the open page does.** The stop ends the session's page as it always has: it
draws `The session stopped.` and `Open the session again, then reload this page.
The page's own link still works, so a fresh one is not needed.` and closes with
1000. That behaviour is kept. The task resumes the session whether or not the page
is there, so a reload after a few seconds finds the session running, session-only,
with the invitation buttons where the sentence was. The admin page does not end:
its UI session and its component do not depend on the session, and its next read
shows the new scope.

**A running turn.** The owner's ruling is stop, isolate and resume as one task, so
a session in the middle of a turn is stopped as part of it, and the confirm is the
guard: the question names that the session will stop. A session whose stop does
not complete in 15 s is `NotStopped`: the stop was issued and still completes, and
once the session is saved a second press moves it and leaves it saved.

**What was considered.**

- **A control command.** A fourth command beside `sessions.stop`, `sessions.isolate`
  and `sessions.open` would add a wire frame to run three steps a client can
  already run in order. The terminal's three commands are unchanged and are the
  same operations the task runs.
- **Refusing a busy session ("Stop the session first").** Rejected: it leaves the
  owner the terminal procedure the feature exists to remove, and the confirm already
  names the stop.
- **Navigating the page that asked to the resumed session.** The page is ended by
  the stop before the task can mint a ticket for it. Keeping the page open across
  the stop would need the socket to hold a close that the relay has asked for, a
  change to `Phase` for a path used once per session. The reload is one step and the
  words say it.
- **Resuming a saved session.** Rejected: a button that said nothing about running
  the session would start it.
- **A new `isolate` flag to copy the transcript.** `loomd access isolate` shares
  the existing transcript with the people invited later, which the confirm now
  says. Copying and redacting history is a separate feature.

**Cost.** One unlinked process per task for up to about a minute, and a stop and an
open of the session on the registry's turns. The credential's grant allowance is
untouched.

**Tests.** `daemon_shareable_test` (the real registry: a running session stopped,
isolated and resumed; a saved one isolated and left saved; a member, an unknown
session and an already shareable one; a stale epoch restoring a running session;
`NotResumed` and `Stranded` and the state each leaves), `ui_route_test` (the
capability by role, the forced asks of a member operator, an owner's read-only page
and an ended page, the whole task through a real session and an invitation refused
before and made after, and `MakeShareable` in the admin page's table of
refused standings), `ui_socket_test` (the capability, and none for a bookmark), `make_shareable_test` (the
session page's states, the confirm guard, the refusal, an unasked answer),
`admin_test` (the question, the guard, the saved variant, the running words, the
refusal) and `grants_test`.

## Addendum: archiving from the sidebar (2026-10-05)

**Status**: IMPLEMENTED in the change that adds it (the owner's request to archive
sessions directly from the sidebar). It adds no route, no admitted event and no
control command. It adds one `Action`, `StopArchive`, to the session actions
above, one capability to the session page's transport, and one field to the
session attachment.

**The problem.** The home's table offers Stop, Archive and Delete beside each row,
but the sidebar, the column the owner keeps in sight, offered only a way to open a
session. To clear a finished session away the owner had to go to the home page.

**What changed.**

- **A quiet button on each row.** Each sidebar row other than the one on screen
  has a button after the row's own button (`view/archiving`): `Archive` on a saved
  or blocked row and `Stop and archive` on a running one. The stylesheet shows it
  on hover and on keyboard focus and keeps it in the tab order while hidden, so
  the keyboard always reaches it; on a device with no hover it is always shown. It
  is drawn after the row's own button, so no pinned path moves: the sidebar is
  still at `0\t1` and the home's table at `0\t2\t1`.
- **One question, then the request.** A press sends `SidebarArchiveAsked` on the
  home and `AskingArchive` on a session page, and nothing is asked of the daemon.
  The row's words are replaced by one sentence in fixed words, the session's name
  beneath it as a text node, a confirm button and a Cancel. A running row's
  sentence names both steps: `Stop this session, then archive it?`. Which action a
  press means is decided by the server from the row's residency in the page's own
  list (`archiving.action`): the message carries only the session. The confirm
  message carries only the session too, and acts only when the open question is the
  sidebar's for that session (`archiving.confirmed`), so a stale click on the
  sidebar's confirm button cannot answer the table's Stop or Delete question, and
  the table's Delete confirm cannot answer the sidebar's.
- **`StopArchive` is one task.** The daemon stops the session, waits up to
  `stop_wait_ms` for the registry to hold it saved, and archives it, in the one
  `manage_task` the home's Stop and Archive already use, so the page's runtime
  never waits and holds no stop answer to chain a second request from. A stop that
  outlasts the wait is a stop that was made, so the archive is refused as busy and
  the page says the session is still running; the owner presses again. A session
  that was already saved is archived all the same.
- **The same authority as the home's Archive button.** The session page is handed
  the capability by the same function, `ui_socket.home_manage_capability`: the
  owner, a page minted to operate, a `Workspace` reach and a `Fresh` origin. A page
  a bookmark resumed, a member's page, a read-only link and a page of one session
  (`loom ui --session`) draw no button and ignore the messages. `manage_for`
  re-derives all of it at the click, as it does for the home, so nothing is trusted
  from the page.
- **The session on screen has no button.** Stopping it ends the page that asked,
  and the task is linked to that page's runtime, so the archive would never run.
  The row says so in its `title`. Archiving it by navigating home after the stop
  would need a ticket minted for a page that is ending, which is not trivial.
- **The table and the sidebar draw their own questions.** The home's single
  `acting` stage serves both; the table treats the sidebar's two actions as calm
  (`home_table.in_row`), so a state is never drawn twice.
- **`Attachment` gains `sessions_directory`**, the daemon's own directory the
  home's attachment already carries, so the session page's `manage_task` is the
  home's. Only Delete removes anything from it, and a session page never offers
  Delete. No page supplies it.
- **Names are text nodes.** The question names the session as a text node and the
  button's title is a fixed string.

**What was considered.**

- *Chaining the stop and the archive in the page*, from the stop's answer. The
  page would hold a follow-up in its model and the session page would need the
  state on both pages. One daemon task is the terminal's own sequence and has one
  answer.
- *Offering the action on the session on screen and ending on the home page.*
  Rejected for the reason above.
- *Offering it on the home's sidebar only.* A session page reached from a fresh
  home has the same standing, so the capability is the same function and the
  restriction would have cost the owner the column they use most.

**Cost.** One variant on `Action`, one transport field and one message on the
session page, one field on the attachment, and a stylesheet block. The sidebar's
memo gains the archive stage in its key.

**Tests.** `sidebar_archive_test` (the button by capability on both pages, the
question and its escaped name, the ask once, the action each residency gives, a
stale or forged confirmation, each question in its own place, the refusal words and
the click paths), `home_test` and `sidebar_test` (their counts), `ui_route_test`
(`StopArchive` against a real registry and in the table of refused standings).
