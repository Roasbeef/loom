# The web view's workspace mode: a home, new sessions, an admin page and a chosen name

**Status: proposed; amended 2026-10-03 after the owner's rulings.** This
note answers the owner's request of 2026-10-03 for the web UI: "a mode
where I can use it like a traditional system, so: make sessions, switch
between them, admin interface where I can invite ppl to read/write sessions,
when a multiplayer then they can choose an identifier". It says what the
tree already has, what is new, why each new piece is shaped the way it is,
what it costs a stolen page, and the order to build it in. The wire and
route changes it needs are drafted in
[protocol-change/065](../../protocol-change/065-web-workspace-mode.md); this
note is the reasoning and the plan, 065 is the rule.

The owner ruled on four of the note's questions the same day (section 9):
a browser login lasts thirty days; a browser-only invitee gets a cookie
that is itself a credential, "like a macaroon", and is never shown a key
to paste; a session created from the browser is created in a workspace the
owner already has one in; and an operator-ceiling page may open a saved
session through the control command's checks. The other recommendations
stand. Section 1.4 is the macaroon design those rulings asked for, and
section 9 says where it changes an earlier answer. A security review of
that design (2026-10-04) found one mistake, that the login's public
identifier could have authenticated as a bearer, and a set of bounds and
clarifications; this edition folds them in, and the owner ruled two of its
questions the same day: the admin page and device links are minted only
from a fresh home, never from one a login resumed (section 9).

**PR 8, the browser login, is built (2026-10-04).** What it changed from this
note's text, and why, is in the PR 8 addendum at the end of 065: the credential
kind travels with the digest, `bind` counts logins, the catalogue gains two
columns (the login's expiry and its parent), the origin is a field of the grant
as section 7 says, and a chain carries its origin and login. The admin page's
Admin button refuses a resumed home, and the admin page lists each principal's
sign-ins with a two-step revoke, as section 4 says.

It builds on [protocol-change/051](../../protocol-change/051-web-view-route.md)
(the page, its three secrets, switching, the invite control),
[053](../../protocol-change/053-owner-admin-and-claims.md) (claims, `loom
access`, the admin page that was designed and not built), the
[web design note](web-design.md) (the A2 shell this extends) and
[the web view](../architecture/web-view.md) and
[multiplayer](../architecture/multiplayer.md) architecture pages. Remote
access ([052](../../protocol-change/052-web-view-remote-origin.md)) is still
a proposal; everything here assumes a loopback `Host`, and says where 052's
`Remote(origin)` would change an answer. Nothing here puts TLS in `loomd`.

## 0. The shape in short

Today a browser reaches exactly one session's page through a 60 second
ticket that `loom ui --session ID` mints; the page's cookie, key and nonce
name that one session and nothing else. This note adds two more kinds of
page under the same ticket, cookie, key and nonce machinery, one browser
login beneath them, and changes nothing about how a session page is
admitted:

- **A home page**, not bound to a session, that lists the sessions the
  principal holds, grouped by workspace, and opens any of them, a saved
  one included. It is the app's front door: the sidebar the session page
  already draws becomes the navigation of the whole app, and every session
  page opened from a home can get back to it. The owner's home also
  creates sessions and opens the admin page.
- **An admin page**, for the owner only, fifteen minutes long, that lists
  principals, memberships and sign-ins, invites per session with a role,
  changes a role, revokes a membership, a credential or one sign-in, and
  rotates a credential. It is 053's phase 4 page with the grants the owner
  has since asked for, bounded the way the session page's invite control
  already is.
- **A browser login** that lasts thirty days: a cookie whose value is a
  credential the daemon minted and can verify from a root key alone, a
  macaroon. It is set when `loom ui` opens a home and when a browser claim
  binds, and it lets the browser mint a fresh home page any day for a
  month without `loom`. Pages minted from it are the eight-hour pages of
  today, with their nonce and `Origin` checks unchanged. A person without
  `loom` is never shown a key to keep; their login is their credential,
  and revoking it is one row.

The invitee's name is a label on an authenticated principal and nothing
more: it is set when the claim binds, it goes into presence rows and
authorship exactly as the inviter's choice does today, and it changes no
check anywhere.

## 1. The home page and how a browser gets into it

### 1.1 What exists

A UI session is a `Grant` (`ui_sessions.gleam:310`) of one session, one
credential digest, one principal and one ceiling, kept with the digests of
the page's cookie, key and nonce in one actor. A ticket for it is minted
only by `UiLink` (`client/daemon/server.gleam:2081`) over the principal's own
control connection, after `session_authority`
(`client/daemon/manager.gleam:936`) finds a membership, and by a page
switching to another session (`ticket_for` (`ui_socket.gleam:1335`)). The
exchange redeems it once (`redeem` (`ui_sessions.gleam:737`)), the page and
its socket are re-authorized on every request (`page_grant`
(`client/daemon/server.gleam:356`)), and every route is checked in 051's
order: `loopback_host` (`ui_http.gleam:203`), then `navigation_allowed`
(`ui_http.gleam:202`) for a page, `origin_matches` (`ui_http.gleam:385`) for
the socket, then the cookie under the key. The cookie's `Path` is the key's
(`set_cookie` (`ui_http.gleam:487`)), so it reaches no other page and no other
loopback port. A UI session lives eight hours (`session_ms`
(`ui_sessions.gleam:79`)); a chain of switches ends with the page it began
from (`mint_before` (`ui_sessions.gleam:572`)).

The operator page already lists the principal's sessions in a sidebar,
read with the page's credential digest (`listed_for`
(`ui_socket.gleam:663`), `authorized_page`
(`client/daemon/manager.gleam:1263`)), grouped by workspace (`grouped`
(`web_view/sessions.gleam:154`)), and a row for a running session is a button
that mints a ticket and navigates (`view` (`web_view/view/sidebar.gleam:94`),
`target` (`web_client/switch_rule.gleam:46`)). The observer page has no
sidebar, by ruling (051, the addendum on the session sidebar): an observer
link is the one a person hands to someone who may only watch one session.

A credential is a 32-byte bearer whose SHA-256 the catalogue keeps
(`bootstrap_owner` (`storage/access.gleam:425`)); every check anywhere takes
a digest. Nothing in the tree signs or verifies a token: `gleam_crypto`
1.6.0 is a dependency of `host` already and provides `hmac` and
`secure_compare`, which section 1.4 uses, so the macaroon needs no new
dependency.

There is no page without a session, no browser credential, and no way for
a page to learn where it came from.

### 1.2 One grant, three scopes, and a reach

The smallest change that gives the browser a front door is to let a grant
name something other than one session. 065 replaces `Grant.session_id` with
a `Scope`:

- `Session(id)`: today's grant, unchanged in every check.
- `Home`: the principal's home page. Its socket runs a new component,
  `web_view/home`, over no lane. It carries the ceiling, as a session grant
  does, and the ceiling caps every ticket minted from it.
- `Admin`: the owner's admin page (section 4). It lives fifteen minutes
  (053's bound), not eight hours.

A grant also gains a `Reach`, which records what the link was minted for:

- `OneSession`: a link `loom ui --session ID` printed. Exactly today's page.
  Its sidebar rules do not change: an operator page lists and switches, an
  observer page draws no sidebar and nothing that names another session.
- `Workspace`: a page minted from a home, or a home itself. A `Workspace`
  session page draws a "Home" control, on the observer page as well, and
  on an operator page the sidebar as today. A home mints `Workspace`
  tickets; `ui.link` with a `session_id` mints `OneSession`, as it does
  now.

`Reach` is why the observer ruling survives unchanged. The ruling exists so
that a handed-out observer link discloses one transcript and not the
principal's project list. A page that came from a home was opened by the
person who already saw the list, and a "Home" button on it discloses
nothing the home did not. The two cases are told apart by the ticket, which
the daemon minted, and never by anything the page says about itself. An
observer `Workspace` page still has no list, no sidebar and no switch: the
one control it gains is a button whose message is fixed (`GoingHome`) and
whose answer is a home ticket for the same principal and the same ceiling.

A `Home` grant records one more thing, its `Origin`: `Fresh` for a home
opened by a `loom ui` exchange or a claim, `Resumed` for one the thirty-day
login minted or a page's "Home" control reached. Two actions read it, the
admin page (section 4) and device links (section 1.4), and both exist only
on a `Fresh` home. The bookmark gives the person their sessions; the
terminal gives the owner administration and gives anyone a new device,
which is 053's posture kept under a login (ruled by the owner,
2026-10-04). A ticket a page mints for a switch or the way home carries
the minting page's origin, so a chain from a resumed home stays `Resumed`.

### 1.3 Three ways into a home

**`loom ui [--observe] [--no-remember] [--open]` with no `--session`.**
`run_view` resolves the daemon as it does today (`view_request`
(`tui.gleam:1122`)) and sends `ui.link` with no `session_id`. The daemon
mints a `Home` ticket with the caller's principal and the requested
ceiling, and `loom` prints or opens `/ui/home?ticket=<t>`. The exchange
opens the home page and, unless `--no-remember` was given, also sets the
browser login of section 1.4, so the next visit needs no `loom`. This is
the owner's path, and the path of any member who has `loom`. The owner
token never reaches a browser.

**The browser login**, for the thirty days after either of the other two.
The browser visits its bookmark, `/ui/l/<login key>/home`, and the daemon
verifies the login and mints a fresh home page for it (section 1.4). This
is what "use it like a traditional system" needs: a bookmark that works
tomorrow.

**`POST /ui/claim`**, for an invitee with no `loom` (section 5.3). It
redeems the claim, binds a browser credential, applies the chosen name,
and sets the login.

A sign-in form that takes a pasted credential (`/ui/login` in the first
draft) is not built: with a browser credential that is set by the claim,
nobody holds a key to paste, and a member with `loom` runs `loom ui` once
a month. Dropping it removes one of the two routes that took a secret in a
form.

### 1.4 The browser login: a macaroon

The owner asked for a cookie that "can be credential based, like a
macaroon". This is that design. The reader who knows macaroons will find
the first-party chain and nothing more: no third-party caveats, no
discharges, no binding of one macaroon to another. Those exist in the
literature; none is needed here, and each would be a mechanism with no
caller.

**What a login is.** A credential the daemon minted, carried by the
browser as a cookie, verifiable from a root key the daemon holds plus the
token's own contents, and revocable by one catalogue row. The token is
ASCII, at most 384 bytes, and reads (065 has the byte-level grammar, which
is the one that counts; this is the shape):

```
loomb1:<id>:<caveat>|<caveat>|...|<caveat>:<sig>
```

- `id` is 32 lowercase hexadecimal digits, 16 bytes from
  `crypto.strong_random_bytes`, the identifier of this login. It is not
  secret: the signature is. And because it is not secret it must never
  authenticate anything on its own, which "Authentication carries the
  kind" below is for.
- each caveat is `name=value`, with `name` one lowercase letter and `value`
  from `[A-Za-z0-9._-]` (the alphabet of a principal ID, `valid_id`
  (`storage/access.gleam:1074`), so an ID is a value as it stands). The
  separators `:` and `|` are legal in a cookie value and absent from the
  alphabet, so the token parses without escaping.
- `sig` is 64 hexadecimal digits, the end of an HMAC-SHA256 chain:

```
sig0 = HMAC-SHA256(key: root, data: "loomb1:" <> id)
sigN = HMAC-SHA256(key: sigN-1, data: caveatN)
```

The chain is the macaroon construction: each caveat is signed with the
signature before it, so a holder can append a caveat and compute the new
signature from the old one, and nobody without the root key can remove
one or change one. `crypto.hmac(data, Sha256, key)` is the whole of the
cryptography, and `crypto.secure_compare` the whole of the verification's
comparison; both are in `gleam_crypto`, which `host` already depends on.
No new dependency and no new FFI.

**The root key** is 32 bytes drawn once and kept at `<state-dir>/browser.key`
beside `owner.token`, written with `atomic_write_private`
(`host/bootstrap.gleam:403`) at mode `0600`, and read at start through the
owner-and-`0600` check `read_private_bounded` (`host/bootstrap.gleam:359`)
applies to `owner.token`. It is the one secret that verifies every login;
it never leaves the daemon's host and is never derived from or written
into a token. At start the daemon does one of three things: a readable
32-byte file is the key; a file that is present but unreadable, of another
size, or not the daemon's own private file refuses start, and never
regenerates, because a key that was tampered with or truncated is not a
reason to silently start a new family; and a missing file is the owner's
whole-daemon revocation: the daemon draws a fresh key and, in the same
start, marks every `active` `browser` row revoked in one update and logs
one line saying how many. Without that update the sign-in listings would
show logins that can never verify again as live, and 053's rule 3 would
refuse a browser-first member a fresh claim until the owner rotated by
hand.

**The caveats a login is minted with**, all six, in this order:

| Caveat | Meaning | Checked against |
|---|---|---|
| `p=<principal id>` | whose login it is | the credential row's principal |
| `c=observer` or `c=operator` | the ceiling of every page it mints | the ticket's ceiling |
| `r=workspace` | its reach | the ticket's reach |
| `e=<unix ms>` | expiry: thirty days from minting, fixed, never extended | the clock |
| `k=<32 hex>` | the login key, the path the cookie is scoped to | the request path |
| `n=<64 hex>` | the SHA-256 of the login nonce (below) | the nonce the browser posts |

**Attenuation later, by the daemon.** Because verification walks the
chain and then takes the intersection of what the caveats allow, a token
with more caveats is a narrower token and verifies against the same root
key and the same row. The rules the first cut already enforces, so that a
later minting can narrow and never widen: a name may repeat, and a repeat
narrows; a wider repeat is ignored and the narrower value holds. `c` takes
the smallest ceiling; `e` the earliest expiry; a future `s=<session id>`
restricts the login to that one session, and two different `s` values
allow nothing; `p`, `r`, `k` and `n` may not repeat with another value; an
unknown name refuses the token. Attenuation is a daemon act: the cookie is
`HttpOnly`, so no script in the browser can read a token, let alone extend
its chain, and a narrowed token is minted where the wide one was, by the
daemon, from the root key. Nothing in this note mints one. When something
does (a "read-only link to this one session for a day" is the obvious
case), a token carrying `s` mints only a session ticket for that session
and never a `Home`, because a home's own asks (its sign-in rows, "sign out
everywhere", a device link) are the principal's and not the session's, and
a narrowed holder must reach none of them. The chain and the intersection
are what make that cheap; they do not make it free, and the design note
that adds it says what the narrowed holder may ask.

**What the daemon stores.** Two things, and never the token:

- the root key file;
- one row in `access_credentials` per login, with `digest` the SHA-256 of
  the identifier's 32 ASCII hex characters, the principal, the state, and
  three new columns: `kind` (`bearer` or `browser`), `issued_at_ms` and
  `last_resumed_ms` (catalogue version 5; 065 has the migration).

Keying the row by the digest of the identifier is what makes a login fit
the existing model: every check in the tree takes a credential digest
(`authenticate` (`client/daemon/manager.gleam:1297`), `session_authority`,
`frame_authority`, `administer`), and a page minted from a login carries
that digest as its `Grant.credential`. The page's socket, its relay, the
gateway's per-frame re-check and the admin dispatch all run unchanged
against that digest, so revoking the row ends every page the login minted
at its next frame, exactly as revoking a bearer does today.

**Authentication carries the kind.** The identifier is in the cookie, so
anyone who sees the cookie knows it, and the row's digest is the digest of
it. The first edition of this note said a login presented as a bearer is
refused because the daemon would hash the whole token; that was true and
beside the point, because the daemon hashes any presented string
(`credential` (`client/daemon/server.gleam:722`)), and `Authorization:
Bearer <id>` would have hashed to the row and authenticated as the
principal with no ceiling, no expiry, no key and no nonce: for the owner's
login, owner authority on the control socket. The review of 2026-10-04
found it, and the fix is in the model, not the token:

- every place a presented string is hashed into a digest, which is
  `/v2/control`, `/v2/claim` and the session attach, looks up only
  `kind = 'bearer'` rows, and a page grant looks up only the kind its
  ticket was minted under (`browser` for a login's pages, `bearer` for a
  `loom ui` ticket's);
- the kind is a parameter of the query itself: `access_credential`
  (`storage/sql.gleam:70`) gains `AND kind = ?`, and `authenticate`
  (`storage/access.gleam:827`) takes the kind, so no caller can forget it;
- as a second layer, `credential` refuses a bearer that is not exactly 64
  lowercase hex characters before hashing it, which is the shape every
  bearer has had since 053, so a 32-character identifier is refused before
  the catalogue is asked.

With that, the bare identifier, the whole token and any other string that
is not a bearer are `401` on `/v2/control`, and a bearer's digest never
satisfies a page grant minted from a login. `loom --token` and
`--token-file` refuse a value beginning `loomb1:` as they refuse
`loomclaim_`, which is a courtesy to the person and not a defence. The two
queries that assume one active credential per principal,
`principal_active_credential` (`storage/sql.gleam:301`) and
`active_member_credentials` (`storage/sql.gleam:251`), gain `kind =
'bearer'` as well, so `principals.list` keeps reporting the bearer or the
claim and never a login's fingerprint in its place; 053's "rule 3 is what
lets `credential` be one value per principal" holds for bearers, and
logins are counted beside it.

**Verification**, at `POST /ui/l/<key>/home`, in order: the host and
`Sec-Fetch-Site` as for every exchange; every `loom_login` value the
request carries is tried, up to four, as `keyed_page`
(`client/daemon/server.gleam:552`) tries every page cookie, and the first
whose chain verifies is the login, so a value a hostile port planted under
a longer path (which the browser sends first) cannot deny the person their
own; a value parses as the shape above, else it is passed over; the chain
recomputes from the root key and `secure_compare` matches `sig`, else
passed over (nothing after this runs on a forged token, so the catalogue is
never asked about one); every caveat holds, with `k` equal to the path's
key, `n` equal to the SHA-256 of the nonce in the body, and `e` after now,
else `401`; the row is found, is `active`, is `browser`, and names the
principal `p` names, else `401`. Then the daemon mints a `Home` grant for
that digest, at the ceiling `c` gives, reach `Workspace` and origin
`Resumed`, and answers the enter page with a fresh page cookie, key and
nonce, as the exchange does. The page is an ordinary eight-hour page. The
daemon logs `daemon.login_resumed` with the login's fingerprint, so the
trail is one line per event, and writes `last_resumed_ms` when the row's
value is older than an hour, so a visit is one registry read and rarely a
write. The name says what it is: the instant the login last minted a home,
not the last time a page it minted was used, which the gateway's per-frame
check does not record. The resume page and the claim form are the two
documents whose policy says `form-action 'self'` where every other `/ui`
document says `'none'` (`content_security_policy`
(`web_view/page.gleam:314`)); nothing else in the policy widens.

**Cookie attributes.** On loopback:
`loom_login=<token>; HttpOnly; SameSite=Strict; Path=/ui/l/<key>;
Max-Age=2592000`. Under 052's `Remote(origin)`:
`__Host-loom_login=<token>; Secure; HttpOnly; SameSite=Strict; Path=/;
Max-Age=2592000`, as 052 does for the page cookie, with the key still in
the route. `Max-Age` is thirty days, the same instant `e` names; the
browser drops the cookie when the token stops verifying. The `__Host-`
form has `Path=/`, so under 052 a browser holds one login per origin: a
second `loom ui` on the same browser overwrites the first's cookie and
leaves its row live until it expires or is revoked, and `k` then names only
the row a resume is for. The sign-in list shows the orphan, marked as not
this browser, and the person revokes it.

**Three secrets again.** 051 put a page on a cookie, a key in the path and
a nonce in `sessionStorage` because a browser sends a cookie to every port
of a host, and a server the session's agent runs on another loopback port
would otherwise receive it. A login that lasts a month needs the same
three, and the macaroon carries two of them as caveats:

- the **cookie** is the token, scoped by `Path` to the login key, so a
  link to another port carries it only if the link holds the key;
- the **login key** `k` is in the bookmark's path, so a bookmark pasted
  into a composer leaks it, as a page URL does today;
- the **login nonce** is 32 random bytes delivered once, in the body of the
  response that set the cookie, and kept by the enter script in
  `localStorage` under `loom.login.<key>`, through the `storage_write` the
  layout already uses. `localStorage` is scoped to scheme, host and port,
  so no page on another port can read it, and the content security policy
  admits no script that is not the daemon's. Its digest `n` is a caveat,
  so the daemon stores nothing for it.

`GET /ui/l/<key>/home` therefore serves a small fixed page whose script
reads the nonce back and submits it in a same-origin form `POST` to the
same path; the `POST` is the verification above. A tab with no nonce (a
new profile, cleared storage) is told to run `loom ui` or to open a device
link (below). `localStorage` is the right store and not `sessionStorage`:
the latter dies with the tab, which a bookmark must survive; both are
scoped to the origin, port included; tabs of one origin share
`localStorage`, which is what a bookmark opened in a new tab needs. A
private window has neither the cookie nor the nonce and signs in afresh. A
cleared `localStorage` leaves a live row the person cannot use; the home
marks "this browser" by matching `k`, so the person sees the rest and
revokes them.

**What the ports share, and what `n` buys.** Browsers scope cookies by
host and path and not by port, and `SameSite=Strict` treats
`127.0.0.1:4000` and `127.0.0.1:9999` as the same site. So a page on
another loopback port can do two things: receive the login cookie, if it
serves a path under `/ui/l/<key>/` on its own port and lures a navigation
there, which needs the 128-bit key that leaks only through the bookmark's
URL; and make the browser send the cookie to the daemon, by navigating to
or posting at the resume route. The second is refused twice, by
`Sec-Fetch-Site: same-site` on both the `GET` and the `POST`, and by the
nonce the other port cannot read. `HttpOnly` keeps the cookie from every
script on every port. `localhost` and `127.0.0.1` are different cookie
hosts, so a login set on one does not resume on the other; `loom ui`
prints one stable host, and the resume page's "run `loom ui`" line names
it. The nonce `n` buys exactly three things and the reader who would
simplify it away should know which: a planted cookie cannot fix the person
to an attacker's login (the attacker's token has the attacker's `k`, and
the victim has no nonce under it); a disclosure of the cookie jar alone, a
cookie file or a `Cookie` header in a proxy or a log under 052, is useless
without it; and nothing more. It does not help against a process that
reads the browser's profile, which 051 does not defend against and this
note does not either, and under 052 the proxy sees the cookie and the
nonce alike, so it defends nothing against the proxy's operator, who is
in the trusted computing base already.

**A stolen login** is worth thirty days of everything a home at its
ceiling can do: every session the principal holds, at the role the
principal holds there; for the owner, sessions in known workspaces and
fifteen-minute admin pages, each under the allowances of sections 2 and 4.
That is the owner's ruling, and this note bounds it four ways rather than
shortening it:

- **Expiry is fixed at minting.** No sliding window: a login used every
  day still ends on day thirty, so a stolen cookie that is used does not
  renew itself. Renewal is the person's `loom ui`, or a device link.
- **Every login is listed and revocable.** A member's home lists their own
  sign-ins (issued, last seen, this browser marked) with "sign out" per row
  and "sign out everywhere"; the admin page lists every principal's with
  revoke; `loom access signins PRINCIPAL` and `loom access revoke-login
  FINGERPRINT` do the same from a terminal; `revoke-credentials` and
  `rotate` revoke bearer and browser credentials alike, as today they
  revoke "every active credential".
- **`last_resumed_ms` makes resumption visible.** A login that minted a
  home at hours its person was not at a browser is the signal, weak but
  present, that the row gives; the home draws it beside each sign-in, and
  `daemon.login_resumed` keeps the full trail. It says nothing about the
  pages a login minted earlier being used.
- **The root key is one file.** Deleting it ends every login daemon-wide,
  and the next start marks their rows revoked so the listings agree.

**Rotate on use** (a fresh token on each visit, the old one refused, reuse
detected) was considered and is not recommended. It needs the daemon to
store the current identifier per login and to replace it on every visit,
which gives up "store only the root key and a row"; two tabs that visit at
once race, and the loser is signed out; and a thief who uses the token
first signs the owner out, which is detection by lockout. Fixed expiry,
listing and last-seen give the owner the same facts without the race.

**The owner's own `loom ui` sets the same login.** One mechanism: the
exchange that `loom ui` opens sets the cookie and the nonce unless
`--no-remember` was given, and the owner's row is a `browser` credential
of the owner principal, so `administer` authenticates it as the owner and
every owner action on a page runs as it does from a page today. The owner
token is untouched: revoking the owner's login revokes a row, not
`owner.token`, and the owner's terminal keeps working. An owner who wants
no thirty-day credential in a browser passes `--no-remember` and renews
by `loom ui` each day, which is today's rule.

**Adding a device.** A browser-only member has no key to carry to a second
browser. A `Fresh` home therefore has "sign in another device", which
mints a `Home` ticket that lives ten minutes instead of sixty seconds and
whose exchange sets a login; the link is shown once in a copy box and the
person opens it on the other device. Three rules bound it (ruled by the
owner, 2026-10-04):

- only a `Fresh` home mints one: not a home the login resumed, and not a
  home reached through a chain of switches. A stolen bookmark cannot make
  a second credential; a stolen fresh page can, inside its eight hours
  and the allowance;
- a device link minted while a login is in play (a claim's home, which set
  one) inherits that login's `e`, so no family of logins outlives the one
  it began from; a device link from a `loom ui` home with `--no-remember`
  has no issuing login and gets thirty days of its own;
- `daemon.login_issued` names the issuing login's fingerprint when there
  is one, so a family can be traced from any member and the admin page can
  revoke it as a group.

It costs one unit of the credential's grant allowance (three an hour,
section 4), and each is listed as a sign-in the moment it is redeemed.

**Relation to claims.** 053's rule 3 says a member has either one open
claim and no active credential, or no open claim. A browser claim gives
the principal its first credential, a `browser` one, and the rule holds as
written. A browser-first member who later wants `loom` asks the owner to
`rotate`, which revokes every credential, their logins included, and
issues a claim for `loom claim`; they then sign the browser in again with
`loom ui`. A `loom`-first member who runs `loom ui` gets a login beside
their bearer, since a login is not a claim.

### 1.5 Routes and checks

| Route | Check order | Answer |
|---|---|---|
| `GET /ui/home?ticket=<t>` | host, `Sec-Fetch-Site` none or same-origin, redeem a `Home` ticket | the enter page; page cookie `Path=/ui/p/<key>`; page nonce in the body; and for a remembered ticket the login cookie and the login nonce |
| `GET /ui/p/<key>/home` | host, `Sec-Fetch-Site`, page cookie under the key, credential authenticates | the shell for the home |
| `GET /ui/p/<key>/home/ws?csrf-token=<n>` | host, `Origin`, page nonce, page cookie, credential | the home socket |
| `GET /ui/l/<key>/home` | host, `Sec-Fetch-Site` | the fixed resume page, which posts the login nonce |
| `POST /ui/l/<key>/home` | host, `Sec-Fetch-Site` same-origin, body at most 1 KiB, the login verifies (section 1.4) | the enter page for a new `Home` grant |
| `GET /ui/claim` | host, `Sec-Fetch-Site` | the claim form, a fixed document |
| `POST /ui/claim` | host, `Sec-Fetch-Site`, body at most 1 KiB, claim redeems | the enter page, with the login cookie and nonce (section 5.3) |

A `Home` ticket presented at a session's exchange, or a session ticket at
the home's, is spent and refused, as `OtherScope` (`ui_sessions.gleam:389`)
spends one presented against the wrong session today. The scope is part of
the redemption, in the same actor message, so the property 053 wanted from a
separate admin ticket table (a session ticket never redeems at the admin
exchange) holds with one table.

A home's `page_grant` checks the page cookie, the key and the credential
and skips the membership check, since there is no session; everything the
home then shows is read with that credential digest and is what the
principal is entitled to see. The page cookie keeps no `Max-Age`: a page
is eight hours, and only the login is thirty days.

### 1.6 What the home draws

The home is the A2 shell (`view` (`web_view/view/shell.gleam:100`)) with the
same four children in the same order, so the two pages feel like one app
and the stylesheet needs no second layout:

0. The top bar: the brand, "Home", the principal's display name, and a
   badge for the home's ceiling ("operator" or "read-only").
1. The sidebar: the principal's sessions by workspace, exactly the session
   page's sidebar (`grouped`), with a "Home" entry above the groups marked
   current, and on the owner's home a "New session" button under each
   workspace heading (section 2). On the home every running session's row
   is a button, and every saved session's row is a button on an
   operator-ceiling home (section 3).
2. The centre: the same sessions as a table with the detail a sidebar row
   has no room for: name, workspace, resident or saved, created, and for
   the owner the domain scope (`workspace_private` or `session_only`, which
   decides whether it can be shared). Below it, the principal's sign-ins
   (section 1.4), with "sign in another device" on a `Fresh` home only.
   The owner's `Fresh` centre also holds the create form and an "Admin"
   button; a `Resumed` owner's home has the create form and no Admin
   button. The bookmark
   `/ui/l/<key>/home` is drawn as text when the page was opened by a
   remembered login, so the person can keep it.
3. The panel: not drawn. The shell hides an absent right column.

Nothing on the home comes from a session: no transcript, no agent text. The
names and paths are the catalogue's, written by the owner or the host, and
are drawn as text nodes as the sidebar draws them. The list is read when the
home opens and at most every 30 seconds after, as the sidebar's is; the
read runs in a relay process, not the component's, so a slow registry does
not freeze the page (the sidebar's read blocks the component today, which
051 accepted for a read that returns at once; the home's reads and opens
can take longer, section 3).

The home has no composer, no lane and no `session_view` state. It holds
session logic as the sidebar does, which is none.

### 1.7 Security

The threat model is 051's: the session's agent reaches the loopback
listener unless `--network off`, browsers send cookies to every port of a
host, and a page stands on a cookie, a key and a nonce. The home and the
login add these cases.

- **A stolen home page** (its three page secrets, by a profile read) is
  worth, for a member, the list of their sessions and an operator page on
  any running one they operate, for up to eight hours: that is what a
  stolen operator page is already worth after the switching addendum. A
  stolen `Fresh` home is worth more than eight hours: it can mint a device
  link, which the thief redeems into a thirty-day login at the page's
  ceiling, three an hour under the allowance, each listed as a sign-in and
  traceable to the page's login when it has one; so a stolen fresh page is
  a stolen login until the person revokes it, and 051's "eight hours" is
  no longer the whole price of a fresh home. A stolen `Resumed` home mints
  no device link and stays eight hours. For the owner a fresh home is
  worth more still: a session in any known workspace (section 2) and
  fifteen minutes of the admin page (section 4), each bounded below. The
  defences are unchanged: `HttpOnly`, `SameSite=Strict`, the key path, the
  nonce in `sessionStorage`, the eight hours, and revocation of the
  credential, which ends every page it minted.
- **A stolen login** is section 1.4's thirty days, bounded by fixed expiry,
  listing, last-seen and revocation. It is the one new durable secret a
  browser holds, and it is the owner's ruling that it exists.
- **CSRF.** The home's actions are Lustre events over its socket, which
  needs the page nonce and an exact `Origin`; no action is an HTTP request a
  cross-site page could make the browser send. The two HTTP `POST`s, the
  login's resume and `/ui/claim`, are refused unless `Sec-Fetch-Site` is
  `same-origin` (the resume) or `none` or `same-origin` (the claim), and
  each needs a secret the attacker lacks: the login nonce, or a claim.
- **A hostile page on another loopback port** receives the page cookie for
  a path holding the page key, and the login cookie for a path holding the
  login key, as 051 accepts for the former; neither opens a socket or
  mints a home without the nonce that `sessionStorage` or `localStorage`
  keeps on this port alone. `Referrer-Policy: no-referrer` keeps both keys
  out of `Referer`.
- **An observer escalating.** An observer-ceiling home or login mints only
  observer tickets (`mint_before` carries the page's ceiling; `c` carries
  the login's). It cannot open a saved session (section 3), create one, or
  reach the admin page: each is refused by the daemon from the grant it
  holds, whatever the socket forwarded, and the home component's observer
  variant has no message that asks.
- **A forged token** costs the daemon one HMAC chain and no catalogue
  read; a token with a valid chain and a revoked row costs one read. There
  is nothing to brute-force: the signature is 256 bits under a 256-bit key.

### 1.8 Left out of the home

- A sign-in form for a pasted credential. Section 1.3.
- Sliding expiry, rotate-on-use, third-party caveats, attenuated tokens.
  Section 1.4.
- Activity badges, strand bars on other sessions' rows, a People list, a
  Goals or Jobs page (the design note's section 2.2 left them out for the
  same reason: they need reads a page does not make).
- Stop, delete, rename or archive a session from the browser. Delete is
  destructive and stop ends other people's work; both stay in the terminal
  and `loom`. The owner can ask for stop later; it would be one fixed
  button per running session on the owner's home, through the same
  `administer` dispatch the invite uses.

## 2. Creating a session from the home

### 2.1 What exists

`sessions.create` is owner-only (`CreateSession`
(`client/daemon/server.gleam:1604`)): it canonicalizes a workspace path on the
daemon's host, canonicalizes or inherits a configuration path, and runs
`create_scoped` (`client/daemon/manager.gleam:1403`) under an idempotency key.
The terminal builds that key from its own identity, the wall clock and a
counter (`CreateSession` (`tui/session_control.gleam:678`)), names the session
from the workspace, and then opens and attaches. A page has no path to any
of this: the ruling of 2026-09-27 says daemon control stays in the terminal.

### 2.2 What is new

An owner's operator-ceiling home (`Owning`, the role `role_of`
(`ui_socket.gleam:514`) already gives an owner's operator page) draws a
"New session" button under each workspace heading and a form in the centre
with two fields: a name, and a "shareable" checkbox. Pressing a workspace's
button chooses that workspace; the form's submit sends
`Creating(workspace_index, name, shareable)`. The daemon side
(`ui_socket.create_for`) then:

0. requires the page to be open and `Owning`, read from the grant and the
   principal the router authenticated, never from the page;
1. resolves the workspace from the listing the daemon itself drew for this
   page's last read, by index, and refuses an index the listing does not
   have. The browser cannot name a path. Every workspace a session can be
   created in from the browser is one the owner already has a session in
   (ruled by the owner, 2026-10-03);
2. checks the name as the catalogue does (`valid_name`
   (`storage/access.gleam:1088`) is the principal's rule; the registration's
   is the same bound, 256 bytes, no controls) and refuses the rest;
3. builds the idempotency key from the page's serial and a counter the
   socket keeps, so a repeated press cannot create twice;
4. runs `manager.create_scoped` with the canonical workspace, the name, an
   inherited configuration (the empty string: "absence is a registration
   choice"), and `session_only` when "shareable" was ticked, else
   `workspace_private`;
5. opens the new session and mints a ticket for it exactly as a saved
   session is opened (section 3), and the browser navigates to it.

The form has fields, which the invite control deliberately did not (051,
"Letting the owner choose the name... Not taken"). Two are needed here and
both are harmless to a stolen page: a name is a label the catalogue bounds,
and the scope only narrows what the session shares. The one field a stolen
page could do damage with, a path, is not a field.

### 2.3 Why the workspace is chosen and not typed

A free path field would let a stolen owner page create a session in any
directory the daemon can read, and then prompt it. Today a stolen page
reaches only sessions that exist. The widening is real and the request does
not need it: a new workspace is created from a terminal once, and from then
on it is in the list. The owner confirmed this on 2026-10-03.

### 2.4 Security

A stolen owner home can create sessions in known workspaces, bounded by
the registry's capacity and `max_pages`, and prompt them at operator role.
That is a new agent in a workspace the owner already runs agents in, at
the sandbox policy that workspace's registrations carry. It can fill the
catalogue with sessions; a count per credential per hour, as
`reserve_invite` (`ui_sessions.gleam:650`) keeps for invitations, bounds it
(065 proposes ten an hour). The daemon logs no line for a creation today;
065 adds one, `daemon.session_created` with the principal's ID, so a run of
creations from a stolen page is visible in `daemon.log`.

## 3. Switching, and opening a saved session

### 3.1 What exists

A switch is a navigation: the page asks for a ticket, `ticket_for` checks
the membership and that the session is resident (`running`
(`ui_socket.gleam:1012`)), mints with the page's own ceiling and deadline,
and `<loom-switch>` navigates to the exchange. A saved session is text in
the sidebar, and the refusal says to resume it from a terminal
(`reason_words` (`web_view/sessions.gleam:263`)). The ruling "operator
surfaces do not open saved sessions" was about the listing not being
permission to activate; the open must go through the membership- and
epoch-checked path.

### 3.2 What is new

Switching becomes the app's navigation: every page with `Workspace` reach
has a "Home" control, the home opens any listed session, and an
operator-ceiling page opens a saved session (ruled by the owner,
2026-10-03).

**Opening a saved session** (`ui_socket.resume_for`) is the control
command's path, run on the page's behalf with the page's credential digest
and the epoch the page was admitted in:

1. the page is open and its ceiling is Operator;
2. `session_authority` finds Owner or Operator authority in the target: an
   observer member is refused with the words "ask an operator to resume
   it", the check `OpenSession` (`client/daemon/server.gleam:2099`) makes;
3. `open` (`client/daemon/manager.gleam:1081`) is called, which is the same
   registry turn `sessions.open` runs: capacity, `Reserved`, archived, the
   domain slot;
4. the daemon waits for the session to become `Resident`, polling `get`
   (`client/daemon/manager.gleam:1228`) with `weft/poll` for at most
   `resume_wait_ms` (30 seconds), in a managed task, so the page's runtime
   is not blocked: the row reads "Opening…" and a second press asks
   nothing;
5. the ticket is minted as for a switch and dispatched to the component as
   `Linked`, which `<loom-switch>` turns into the navigation.

A failed or slow open is one fixed refusal: "That session did not open.
Resume it from a terminal." The daemon logs the class as it does for any
open (`daemon.session_start_failed`). No text from the open reaches the
page.

**The way home.** A session page's "Home" control sends `GoingHome`, and
`ui_socket.home_ticket_for` mints a `Home` ticket with the page's
principal, ceiling and deadline (`mint_before`), so a chain home and back
ends with the page it began from. `switch_rule.target` accepts a second
shape, `/ui/home?ticket=<64 hex>`, and nothing else new. A ticket a page
mints never sets a login: only `loom ui`, a claim and a device link do.

### 3.3 What changes in the ruling

A page opening a saved session is the daemon starting a runtime at a
browser's request, which the switching addendum said the rulings did not
include. The owner lifted that on 2026-10-03 for operator-ceiling pages,
on the path proposed here: the control command's own, with the same
authority and epoch checks, so the listing is still not permission; the
membership is.

## 4. The admin page

### 4.1 What exists

053 designed the admin page in full (phase 4) and the owner ruled on
2026-09-30 that it waits for use of the terminal's `/access` overlay
(`tui/access_overlay.gleam`). The daemon serves the two owner-only reads it
needs, `principal_page` (`client/daemon/manager.gleam:1139`) and
`membership_page` (`client/daemon/manager.gleam:1162`), and every mutation
through one dispatch, `administer` (`client/daemon/manager.gleam:734`): invite,
set-role, revoke membership, rotate, revoke credentials, isolate. The owner's
session page already starts one of those from a browser, `invite_for`
(`ui_socket.gleam:812`), bounded to three an hour for the credential and shown
once. `loom access` has the whole grammar (`usage` (`host/access.gleam:169`)).

What is missing: a per-session list of members (the listing is per
principal), a list of a principal's logins, any grant other than the
session page's invite from a browser, and the page itself.

### 4.2 What is new

The admin page is its own page kind, scope `Admin`, minted only from an
`Owning` home by pressing "Admin" (`ui_socket.admin_ticket_for`) and living
fifteen minutes from its exchange. The owner's home is unaffected when it
ends; pressing "Admin" again mints another, which a thirty-day login makes
possible on any day. `loom access page`, which 053 proposed, is not built
here; the home's button covers it.

It draws, from `principals.list`, `principals.memberships`, the new
`sessions.members` and the new `credentials.signins` (065):

- **Principals**: name, ID, kind, credential state (`active` with its
  fingerprint and `claimed_at_ms`, `claim_open` with the time left,
  `claim_expired`, `none`), and the count of live logins. An open claim is
  a pending invitation; the page lists them under that heading too.
- **Per principal, their sign-ins**: fingerprint, issued, last seen, with
  a revoke button each. This is where the owner sees a login that is
  active at hours its person was not.
- **Per session**: the members and their roles, and the session's domain
  scope, so the owner sees before inviting whether the session must be
  isolated first.

And it does, each through `administer` with the page's credential digest,
which authenticates the owner and the epoch again in the registry's own
dispatch:

| Action | Fields the form has | Bound |
|---|---|---|
| Invite to a session | role (observer or operator), name | the credential's grant allowance (three an hour, shared with the session page's control and with device links); the claim lives an hour |
| Set role | role | the allowance when the role rises to operator; none when it falls |
| Revoke membership | none, two-step button | none; it reduces |
| Revoke credentials | none, two-step button | none; it reduces; voids an open claim and every login |
| Revoke one sign-in | none, two-step button | none; it reduces |
| Rotate | none | the allowance; the claim lives an hour; every login of the principal ends |

The invited principal is `guest-` and eight hex digits as the session
page's is; the name field is the inviter's suggestion, which the invitee
may replace at the claim (section 5). An invitation and a rotation show the
token and the two ways to redeem it, the `loom claim` command and the
`/ui/claim` address, once, in copy boxes, as the session page does. The
token is in the component's state until the owner hides it, and nowhere
else.

The two-step revoke buttons guard a mis-click and are not a security
boundary, as 053 said. The grant actions are a security boundary and are
held to the same allowance the session page's invite is, kept for the
credential and not the page, so a stolen admin page mints what a stolen
session page can and no more.

### 4.3 Security

053's eight points are kept where the request allows:

- Own flag (`--ui-admin`): dropped (accepted by the owner). The session
  page already grants from the browser without one, and the admin page is
  minted only from an owner's operator home.
- Loopback only: kept. Under 052, a `Remote(origin)` request never mints
  or admits an `Admin` page or the create control; a remote owner uses
  `ssh -L`.
- Minted only for the owner: kept, by the grant and by `administer`.
- Minted only over a fresh step: kept (ruled by the owner, 2026-10-04).
  The "Admin" button exists only on a `Fresh` home, one a `loom ui`
  exchange opened; a home the thirty-day login resumed draws none and the
  daemon refuses `admin()` from it (`ui_socket.admin_ticket_for` reads the
  grant's `Origin`). 053's fifteen minutes was a credential bound because
  the only route to the page ran over the owner token; a page lifetime
  re-mintable from a bookmark would have bounded nothing against a stolen
  owner login. With the fresh-home rule it is a bound again: the owner
  runs `loom ui` on the day they administer, the bookmark gives sessions
  and never administration, and a stolen owner login reaches no admin
  page at all.
- Fifteen minutes: kept, per page, and the home that minted it is
  unaffected when it ends.
- Reduce-only: not kept, by the owner's request. The 051 invite addendum
  already prices a page that grants; the admin page's grants are held to
  the same count, and `set-role` to operator counts as a grant.
- No path to a grant: see the line above.
- No session content: kept. The admin page draws names, IDs, roles,
  states and times, all catalogue fields.
- Own ticket kind, cookie path and lifetime: kept, by `Scope.Admin` in the
  one table and the key-scoped cookie path.

A stolen admin page (its three secrets, inside its fifteen minutes) can
revoke every member, credential and login (a denial of service the owner
repairs by inviting again), read the principal list, and mint three claims
or device links an hour for the credential, each a membership or a login
that outlives the page until revoked. That last is the case 053 named and
the owner accepted for the session page on 2026-09-30; the admin page
widens it from the page's own session to any session, which is what
"invite people to sessions" asks for. A stolen owner login mints no admin
page and no device link; it reaches the owner's sessions and, from a
resumed home, creation in known workspaces. The page cannot reach the
owner token or the root key, cannot change who the owner is, and cannot
grant Owner.

## 5. The invitee chooses a name

### 5.1 What exists

A principal has a stable ID and a display name (`Principal`
(`storage/access.gleam:202`)), set by the inviter (`loomd access invite
SESSION PRINCIPAL ROLE NAME`, and `Guest <digits>` from the page). The
catalogue can rename one (`rename` (`storage/access.gleam:1161`)) and no control
command exposes it (053, Open). A claim binds a credential to the principal
(`claim` (`client/daemon/manager.gleam:659`)) and carried no name before this change. The name
reaches everyone through the roster: the gateway stamps each connection and
each admitted command with the principal's current name (`Origin`
(`client/gateway.gleam:1783`)), presence frames carry it, and an origin keeps
the name it was admitted under after a rename (`Origin`
(`core/message.gleam:33`)). A client-supplied name never establishes
identity: the ID does, the name is a label.

### 5.2 What is new

`credentials.claim` gains an optional `name` (065). When present it is
checked by `valid_name` and applied in the same transaction that binds the
credential, so a refused name binds nothing and the claim stays open for a
second try. `loom claim --name NAME` sends it; the browser claim form
(5.3) has a name field prefilled with nothing and the words "leave empty to
keep the name the inviter chose". The inviter's name is the suggestion, in
the sense that it is what the invitee gets by doing nothing.

Uniqueness: none. Two members may both be "Alice"; the ID is the identity,
and the roster, the Session pane's viewers and the admin page draw the ID's
first eight characters in a `title` beside the name, so the owner can tell
them apart. A uniqueness rule would make a claim fail on a name the invitee
cannot see is taken, and would mean nothing for authority.

Renaming later (`principals.rename`, a member for themselves and the owner
for anyone) is cheap once the name is a request field, and is the last,
optional pull request; it is not needed for the request.

### 5.3 The browser claim

A person with no `loom` cannot run `loom claim`, and the request says the
invitee chooses their name in the UI, so the claim has a browser form.
`GET /ui/claim` is a fixed document with two fields, token and name, and
`POST /ui/claim` does, in the daemon:

1. host and `Sec-Fetch-Site` as for the exchange; body at most 1 KiB;
2. the token must be `loomclaim_` and 64 hex digits, checked before any
   lookup; a claim-shaped token takes a reservation for its digest
   (`root.acquire_claim`, as `/v2/claim` does, so a second post of a claim in
   flight is refused), and there is no separate `claim_known` step: the bind
   (step 3) refuses an unknown, void, expired or already-bound claim inside its
   one transaction;
3. the daemon draws a login (section 1.4): an identifier, a login key, a
   login nonce, and the token with its six caveats for this principal at
   Operator ceiling; and binds `SHA-256(id)` as a `browser` credential with
   `manager.claim`, with the name. The credential the claim binds is the
   login itself; there is no bearer, and nothing is shown to keep (ruled
   by the owner, 2026-10-03);
4. it mints and redeems a `Home` grant for that digest;
5. it answers the enter page with the page cookie, key and nonce, and the
   login cookie and login nonce. The enter script keeps both nonces and
   moves to the home, which draws the bookmark to keep.

The refusals are 053's, in fixed words: unknown or void, expired, bound to
another credential (`conflict`), and a bad name, which binds nothing. A
claim redeemed by the wrong person shows in `principals.list` as
`claimed_at_ms` and as a sign-in the owner did not expect; the owner
rotates, which ends that login and issues a new claim. The wrong person
held the memberships the owner granted from the claim until the rotation,
as 053 says.

### 5.4 Where the name shows

Presence rows and the Session pane's viewers show the name the gateway
stamped at attach, so a name chosen at the claim shows the moment the
person attaches, in every terminal and page. Authorship shows it on every
turn the person submits. The admin page and `loom access list` show the
current name beside the ID. Nothing else changes: the name is never a key,
a path, an attribute or a handler value, and every surface draws it as a
text node as it draws the inviter's name today.

## 6. Frozen-interface impact

Part 1.6 only; 065 has the exact shapes.

| Change | Kind |
|---|---|
| `ui.link`: `session_id` optional; absent means a `Home` ticket; `remember` field | additive |
| New `/ui` routes: `/ui/home`, `/ui/p/<key>/home`, `/ui/p/<key>/home/ws`, `/ui/l/<key>/home` (`GET` and `POST`), `/ui/admin`, `/ui/p/<key>/admin`, `/ui/p/<key>/admin/ws`, `GET` and `POST /ui/claim` | new routes under 051's prefix |
| `credentials.claim`: optional `name` | additive |
| New owner-only read `sessions.members` | new command |
| New `credentials.signins` and `credentials.revoke_login` (self for a member, any for the owner) | new commands |
| `principals.list`: a `logins` count per principal | additive |
| Authentication by kind: a bearer presented on `/v2/control`, `/v2/claim` or a session attach must be exactly 64 lowercase hex and matches only a `bearer` credential; a login matches only a `browser` one | a rule Part 1.6 states; today's bearers are unchanged |
| The resume and claim documents are served with `form-action 'self'` | a header rule under 051's prefix |
| New `principals.rename` (optional, last PR) | new command |

No session-protocol frame changes. The catalogue moves from version 4 to
5 for three columns on `access_credentials` (`kind`, `issued_at_ms`,
`last_resumed_ms`); the schema is not a Part 1 interface, and the
migration is the forward one at `user_version`
(`storage/catalogue.gleam:150`). The per-session members read and the
sign-ins read are new queries over the existing tables (`make gen-sql`),
and three existing queries gain a kind.

## 7. The pull requests

Each lands alone, leaves `make check` green and `make doc-check` clean, and
is reviewed by a Fable advisor pass before the queue. Each names its tests;
the route tests run on a real listener and registry as `ui_route_test` does
today, and the component tests through `lustre/dev/simulate`. Workers read
051's addenda on switching and inviting first: the shape of every new
daemon-side function is `ticket_for` or `invite_for`, and the shape of every
new control is the invite control.

PR 1 is being built from the first edition of this note. Its surface is
kept; what the login needs from it is one thing, named under PR 1.

**PR 1: the home page, read-only.** `Grant` gains `Scope` and `Reach`;
`ui.link` without `session_id`; `loom ui` without `--session`; the home
routes; `web_view/home`, listing the sessions in the shell with the
sidebar; endings for a home. Rows are text. Exit: `loom ui --open` lands on
a home listing the principal's sessions by workspace, resident and saved
marked; a session ticket at the home exchange and a home ticket at a
session's are spent and refused; a member's home lists only their
memberships; a revoked credential's home ends at its next frame. Tests:
`ui_sessions_test` (scope on mint and redeem, `max_pages` per principal for
homes), `ui_route_test` (the three home routes, both wrong-scope
refusals, the credential checks), `home_test` in `web_view` (the listing,
the grouping, text only, no handler), `tui` argument tests for `loom ui`
with and without `--session`. *Room for the login (PR 8):* the response a
redeemed `Home` ticket gets must be built by one function that takes the
redeemed secrets and returns the enter document with its headers, so PR 8
can add the login cookie and the login nonce to that one function for a
remembered ticket and nowhere else; `/ui/l/...` stays `Unknown` in
`ui_http.route`; and the page cookie keeps no `Max-Age`. The `remember`
and `Origin` fields on the grant are PR 8's, not PR 1's; until then every
home is `Fresh`, which is the only kind PR 1 can mint.

**PR 2: navigation.** A home row for a running session mints and
navigates (`ticket_for` reused with the page's ceiling); a `Workspace`
session page draws "Home", on the observer page too, which mints a home
ticket; `switch_rule` accepts the home exchange shape; a `OneSession` page
draws nothing new. Exit: home to session to home in one tab, each page a
new UI session, the chain ending with the home's deadline; an observer
`OneSession` page still has no sidebar and no Home. Tests:
`session_switch_test`, `switch_test` (`web_client`), `ui_route_test` (the
chain deadline through a home, `OneSession` and `Workspace` pages drawn
from tickets of each reach), `page_events_test` (the Home control's path on
both pages).

**PR 3: opening a saved session.** `resume_for` with its managed task and
poll; saved rows become buttons on operator-ceiling home and session pages;
the refusal words. Exit: a saved session opens from the home and the tab
lands on it; an observer-ceiling page's saved rows stay text and a forged
press is refused; an observer member's press is refused with the fixed
words; a `Reserved` or `RecoveryBlocked` row stays text; an open that does
not finish in `resume_wait_ms` mints nothing and says so; a second press
while one is out asks nothing. Tests: `ui_route_test` (resume and land,
each refusal), `ui_socket_test` (`resume_for` steps in isolation with a
stub registry), `home_test` and `sidebar_test` (which rows are buttons at
which ceiling).

**PR 4: creating a session.** The per-workspace button, the form, the
`Creating` message; `create_for`; the creation allowance in `ui_sessions`;
the `daemon.session_created` log line. Exit: the owner's operator home
creates a session in a listed workspace with the typed name and lands on
it; a member's home draws no control and the daemon refuses a forged
submit; an index outside the listing is refused; an invalid name is refused
and nothing is created; the eleventh creation in an hour is refused; a
repeated press creates once. Tests: `ui_route_test` (create and land, the
member refusal, the index refusal, the allowance), `home_test` (the form's
decoder is total, the control's paths, text only), `ui_sessions_test` (the
allowance).

**PR 5: `sessions.members` and the admin page.** The read, its SQL,
`loom access members SESSION`; `Scope.Admin` with its fifteen minutes; the
"Admin" button; `web_view/admin` with the lists and the grant and reduce
actions (the sign-in rows and their revoke came with PR 8); the grant
allowance shared with the session page's invite. Exit: the owner's home
opens an admin page that lists principals, pending claims and a session's
members; each action changes the catalogue and the page re-reads; a
member's `sessions.members` is `forbidden`; the admin page ends at fifteen
minutes and the home does not; a session ticket never redeems at the admin
exchange; the fourth grant in an hour across the admin page and a session
page is refused; a demotion costs no allowance; no frame on the admin
socket carries `loomclaim_` except the one that shows it to the owner.
Tests: a `storage` test for the query, `daemon_access_test` for the
command and the CLI, `ui_route_test` for admission and the lifetime,
`admin_test` in `web_view` for the component, `ui_sessions_test` for the
shared allowance. Mutations, each failing a named test: a member's home
offered the Admin button; the allowance skipped for `set-role` to operator;
the admin exchange accepting a `Home` ticket.

**PR 6: the claim name.** `credentials.claim` with `name`;
`storage/access.claim` applying it in-transaction; `loom claim --name`; the
admin listing showing it. Exit: a claim with a name binds and the principal
carries it; an invalid name binds nothing and the claim stays open; a claim
without a name keeps the inviter's. Tests: `storage` claim tests, the
daemon's decoder test, the `loom claim` encoder test, a route test that
reads the name back from `principals.list`.

**PR 7: credential kinds.** Catalogue version 5 (`kind`, `issued_at_ms`,
`last_resumed_ms` on `access_credentials`, with the migration test 053's
version 4 has); `authenticate` and `access_credential` taking the kind;
`principal_active_credential` and `active_member_credentials` restricted to
`bearer`; every wire-bearer path (`/v2/control`, `/v2/claim`, the session
attach) authenticating as `bearer` and every page grant as the kind its
ticket names; `credential` refusing a bearer that is not 64 lowercase hex
before hashing; `storage/access.claim` taking a kind. No login exists yet,
so the PR changes nothing a person can see, and that is the point: the
HIGH finding's fix is reviewed alone, before any `browser` row can be
written. Exit: a version 4 catalogue migrates to 5 with every credential
`bearer`; a `browser` row inserted by a test authenticates on no `/v2`
route and on no `bearer` page grant, and a `bearer` row on no `browser`
grant; a 32-character, a 63-character and an uppercase-hex bearer are
`401` before the catalogue is read; `principals.list` for a principal with
one `bearer` and one `browser` row reports the bearer. Tests: `storage`
migration and query tests, `daemon_access_test`, `ui_route_test` for the
page grant's kind. Mutations, each failing a named test: the kind dropped
from the `authenticate` query; the shape check removed from `credential`;
`principal_active_credential` without its kind.

**PR 8: the browser login.** The root key file with its start-time rule
(read through `read_private_bounded`; an unreadable or wrong-sized file
refuses start; a missing file is drawn and every `browser` row revoked in
the same start, with one log line); `host/login` (mint, parse, verify,
intersect) with `crypto.hmac` and `crypto.secure_compare`; `Grant.remember`,
`Grant.origin` and `ui.link`'s `remember`; `loom ui --no-remember`; the
login cookie and nonce on a remembered exchange; `GET` and `POST
/ui/l/<key>/home` and the resume page with `form-action 'self'`, trying up
to four `loom_login` values; `daemon.login_issued` (with the issuing
login's fingerprint), `daemon.login_resumed` and `daemon.login_revoked`;
`credentials.signins`, `credentials.revoke_login`, the `logins` count,
`loom access signins` and `revoke-login`; the home's sign-in rows with
"this browser" marked by `k`, "sign out", "sign out everywhere" and, on a
`Fresh` home only, "sign in another device" (a ten-minute remembered
`Home` ticket under the grant allowance, inheriting `e` from an issuing
login); the "Admin" button and `admin_ticket_for` refusing a `Resumed`
home; the admin page's sign-in rows; `loom --token` refusing `loomb1:`.
Exit: `loom ui --open` sets a login; the bookmark mints a home the next
day without `loom`; the thirtieth day refuses it; `--no-remember` sets
none; a token with a wrong signature, a missing caveat, an unknown caveat
name, uppercase hex anywhere, a key not matching the path, a nonce not
matching, an expired `e`, or a revoked row is refused `401`, with no
catalogue read for the first four; a wider repeat is ignored and the
narrower value holds; a token narrowed by an appended caveat verifies and
is held to the narrower value, and one carrying `s` mints a session ticket
for that session and no `Home`; the bare identifier, the whole token and
the identifier's digest presented as a bearer on `/v2/control` are each
`401`; a planted `loom_login` under a longer path does not deny the real
one; revoking one sign-in ends its pages at their next frame and leaves the
principal's other sign-ins; `revoke-credentials` and `rotate` end every
login; a missing root key at start ends every login and marks their rows
revoked, and a truncated one refuses start; `last_resumed_ms` moves at most
once an hour and `daemon.login_resumed` is logged on every resume; a
`Resumed` home draws no Admin button and no device link and the daemon
refuses both from it; a device link redeems once within ten minutes, sets
a login that inherits the issuing login's `e`, appears as a sign-in, is
logged with its parent's fingerprint, and costs one allowance unit; the
token appears in no file under the state root and in no log line. Tests:
`login_test` in `host` (the chain, parsing, every refusal, intersection,
attenuation), `ui_route_test` for the routes, the origins and the
revocations, `ui_sessions_test` for the device-link lifetime and allowance,
`home_test` for the rows and the two controls by origin, `page_test` for
the resume document and its policy, a state-root and log scan, a daemon
start test for the three root-key cases. Mutations, each failing a named
test: the chain compared with `==`; `e` extended on use; a repeated `c`
taking the larger; the row looked up before the chain is verified; the
page cookie given a `Max-Age`; a `Resumed` home offered the Admin button;
a device link minted from a `Resumed` home; a device-link login given
thirty days under an issuing login; a missing root key drawn without the
revocation; only the first `loom_login` value read.

**PR 9: the browser claim.** `GET` and `POST /ui/claim`, binding a
`browser` credential and setting the login. Exit: an invitee with no `loom`
redeems a claim in the browser, chooses a name, and lands on an operator
`Fresh` home with a login set; a spent, void, expired or otherwise-bound
claim is refused in fixed words; a cross-site `POST` is refused; a
bearer-shaped value is refused before any lookup; nothing but the digest is
under the state root; `principals.list` shows the claim redeemed and one
login. Tests: `ui_route_test` for every refusal and the success,
`page_test` for the fixed form and its policy, a state-root scan as
`the_claim_redeems_and_only_its_digest_is_kept_test` does today.

**PR 10, optional: `principals.rename`** and a "Your name" control on the
home for members; the owner renames anyone from the admin page.

PRs 1 to 4 are a chain. PR 5 needs PR 1. PR 6 is independent. PR 7 is
independent and lands before PR 8. PR 8 needs PRs 1 and 7 and, for the
admin rows, PR 5. PR 9 needs PRs 6 and 8. PR 10 needs PR 5.

## 8. What this note leaves out, and why

- **Remote access.** 052 is a proposal. The login and the browser claim
  make it more useful, since they are what a teammate with no `loom`
  needs, and 065 says which of its answers 052 must keep (`Admin` and
  creation stay loopback; the login cookie takes the `__Host-` form).
- **A free workspace path field.** Section 2.3, ruled.
- **A sign-in form for a pasted credential.** Section 1.3.
- **Sliding expiry, rotate-on-use, third-party caveats, attenuated
  tokens.** Section 1.4; the first cut only enforces the intersection
  rules that make a daemon-minted narrower token possible later, and no
  script in the browser can attenuate an `HttpOnly` cookie.
- **Stop, delete, rename, archive from the browser.** Section 1.8.
- **Per-session member lists on the session page.** The Session pane shows
  viewers; members with roles are the admin page's.
- **A composer target menu, Goals and Jobs pages, activity badges.** As the
  design note left them.
- **`loom access page`.** The home's button replaces it; 053's phase 4
  command stays unbuilt.
- **Uniqueness of names, name moderation.** Section 5.2.

## 9. Questions for the owner, and their answers

Ruled by the owner on 2026-10-03:

1. **How long does a browser login last?** Thirty days, a remember-me, not
   eight hours. Section 1.4 is the design; a page minted from it is still
   eight hours.
2. **How does a browser-only invitee get a credential?** A cookie that is
   the credential, macaroon-style, set by the claim; no key is shown or
   pasted. Section 1.4. The first draft's alternative (a key shown once and
   a sign-in form) is withdrawn, and so is the sign-in form.
4. **May an operator-ceiling page open a saved session?** Yes, through the
   control command's own checks (section 3). The ruling "operator surfaces
   do not open saved sessions" is lifted for those pages.
6. **No free workspace path field.** Confirmed; a session is created in a
   workspace the owner already has one in.

Ruled by the owner on 2026-10-04, after the security review:

14. **The admin page is minted only from a fresh home**, one a `loom ui`
    exchange opened, never from a home the thirty-day login resumed.
    Section 4.3. The `Origin` on the home grant carries it.
15. **Device links are minted only from a fresh home**, not a switch-chain
    home and not a resumed one; a device-link login inherits `e` from the
    issuing login when there is one; `daemon.login_issued` names the
    issuing login's fingerprint. Section 1.4.

Recommendations the owner accepted as made, with the ones the macaroon or
the review changes marked:

3. **The default ceiling of a home.** A home minted by `loom ui` without
   `--session` is an operator's unless `--observe`; `loom ui --session ID`
   keeps its observer default. *Changed by the login:* there is no sign-in
   form, so its "read-only box" is gone; a login's ceiling is the `c`
   caveat, fixed from the `loom ui` or the claim that set it (a claim sets
   operator, the home's ceiling capped by the membership as always), and a
   device link inherits the home's.
5. **Default domain scope for a browser-created session.**
   `workspace_private`, with a "shareable" box that makes it `session_only`.
7. **A home lists the principal's sessions at any ceiling.** Yes.
8. **No `--ui-admin` flag.** Confirmed. *Changed by the review:* the
   fresh-home rule of question 14 is what now keeps 053's fifteen minutes
   a bound; without a flag, the fresh step is the gate.
9. **Display names are not unique.** Confirmed.
10. **Self-rename** is the optional last PR.
11. **The owner's credential at `/ui/login`.** Moot: the form is gone. In
    its place: the owner's `loom ui` sets a login like anyone's, and
    `--no-remember` declines it. The owner token itself never reaches a
    browser.
12. **The grant allowance counts `set-role` to operator.** Yes; and now
    device links too, since each is a thirty-day credential.
13. **Build order.** As section 7, now ten PRs: the credential kinds are
    PR 7 on their own, ahead of the login as PR 8, with the browser claim
    as PR 9 behind it.
