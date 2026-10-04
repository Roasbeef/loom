# protocol-change/065: a home page, a browser sign-in and claim, session creation and an admin page on the web view

**Status**: DRAFT 2026-10-03, for the owner's review; nothing implemented ·
**Affects**: Part 1.6 client protocol (`ui.link`, `credentials.claim`, two
new control commands, new `/ui` routes), the `loom ui` and `loom claim`
command lines, and four owner rulings recorded in `docs/next.md` ·
**Raised by**: the owner's request of 2026-10-03 for a web mode that makes
sessions, switches between them, administers access and lets an invitee
choose their name · **Builds on**:
[051](051-web-view-route.md) (the page, its three secrets, switching, the
invite control), [053](053-owner-admin-and-claims.md) (claims, `loom
access`, the admin page designed in phase 4), [054](054-roster-push-on-subscribe.md)
(the roster a page draws names from) · **Design note**:
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
terminal.

The owner asked for four things a browser cannot do today:

1. A page that is not a session's: a front door that lists the sessions
   the person holds and opens any of them, including a saved one.
2. Creating a session from the browser.
3. An admin page: who has access to which session, in which role; invite,
   change a role, revoke, rotate; the invitations not yet redeemed.
4. The invitee choosing the name they are shown under, in the browser.

Four rulings stand in the way, each made for a reason this proposal must
keep or argue against: daemon control stays in the terminal (2026-09-27);
operator surfaces do not open saved sessions; the observer page lists
nothing; and 053's admin page waits for use of the terminal overlay
(2026-09-30). And one gap is structural: a person with no `loom` on their
machine has no way to obtain a credential (`loom claim`) or a ticket (`loom
ui`), so "invite people" to a web UI implies the browser can do both.

## What was considered

### How a browser signs in

- **A browser credential of its own**, with its own issue, rotation and
  revocation. 051, 052 and 053 each declined a second credential kind.
  Rejected again.
- **A long-lived "remember me" cookie** (days or weeks) as the login. It
  is what a traditional system does, and it costs a stolen cookie that
  long. 051 chose eight hours so a copied cookie stops working the same
  day. Not taken as the default; offered as the alternative in the design
  note's question 2 for browser claimants.
- **A ticket for a session-less page, minted the way session tickets are,
  chosen.** `loom ui` without `--session` mints it over the control
  connection; a sign-in form mints it from the credential; the claim form
  mints it after binding. The cookie, key, nonce, eight hours, actor and
  checks are 051's unchanged. One new thing is in the grant: what it is
  for.

### Where a browser-created session may point

- **A path field for the owner.** A stolen owner page could create a
  session in any directory the daemon can read and prompt it, where today
  it reaches only sessions that exist. Rejected for the first cut.
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
  from a page (invite, rotate, a promotion to operator) counts against the
  one allowance 051 keeps for the credential, three an hour. Reductions
  are free. The page lives fifteen minutes, is minted only from an owner's
  operator home, and is loopback-only, as 053 said.

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
  keeping it in storage. A credential in browser storage is what ADR-014
  and 051 refused. Rejected.
- **Option B, the daemon drawing the credential and showing it once,
  chosen.** 053 rejected B for `loom claim` because a lost reply loses the
  credential; in a browser there is no private file to store a credential
  in before sending its digest, so C's advantage does not exist there. A
  lost welcome page is repaired by rotation, as 053 says of B.

### Opening a saved session from a page

- **Keep the ruling**: saved sessions are text, resume from a terminal.
  Fails "switch between them" for anything not already running.
- **Let a page run the control command's own path, chosen**: the same
  authority check (`client/daemon/server.gleam:1630`), the same registry
  turn (`client/daemon/manager.gleam:991`), with the epoch the page was
  admitted in, bounded by a wait, and only for an operator-ceiling page
  whose principal holds Operator or Owner on the target. The listing is
  still not permission; the membership is.

## Proposal

### The grant

`ui_sessions.Grant` becomes:

```
Grant(scope: Scope, credential: Digest, principal: String,
      ceiling: Role, reach: Reach)

Scope = Session(id: String) | Home | Admin
Reach = OneSession | Workspace
```

- `Session(id)` is today's grant in every check. `Home` is the principal's
  home page. `Admin` is the owner's admin page.
- A `Home` or `Session` grant lives `session_ms` (eight hours) from its
  exchange, or the minting page's deadline if earlier (`mint_before`,
  unchanged). An `Admin` grant lives `admin_ms`, 900,000 (fifteen minutes),
  or the minting page's deadline if earlier.
- `max_pages` (four) bounds a principal's live pages per `Session(id)`, as
  today, and separately per `Home` and per `Admin`.
- `reach` is `OneSession` for a ticket `ui.link` mints with a `session_id`,
  and `Workspace` for a `Home` ticket and for every ticket a `Home` or
  `Workspace` page mints. A page's reach decides whether it draws a "Home"
  control; nothing else reads it. An `OneSession` page is exactly today's
  page, observer rulings included.
- A ticket is redeemed only at the exchange of its scope: a `Session(id)`
  ticket at `/ui/sessions/<id>`, a `Home` ticket at `/ui/home`, an `Admin`
  ticket at `/ui/admin`. Presented elsewhere it is spent and refused, as a
  ticket presented against another session is today (`OtherSession`).

### Routes

All under 051's prefix, host-checked first, with 051's headers and policy.
`<key>` and the cookie are 051's; the cookie's path is `/ui/p/<key>`.

| Method and path | Checks, in order | Answer |
|---|---|---|
| `GET /ui/home?ticket=<t>` | loopback host; `Sec-Fetch-Site` `none` or `same-origin`; redeem a `Home` ticket | the enter page; `Set-Cookie`; nonce in the body |
| `GET /ui/p/<key>/home` | host; `Sec-Fetch-Site`; cookie under the key names a live `Home` page; credential authenticates | the shell |
| `GET /ui/p/<key>/home/ws?csrf-token=<n>` | host; `Origin` is `http://` and the `Host`; nonce; cookie; credential | the home socket |
| `GET /ui/admin?ticket=<t>` | as the home exchange, for an `Admin` ticket | the enter page |
| `GET /ui/p/<key>/admin` | as the home page, for an `Admin` page, and the credential is the owner's | the shell |
| `GET /ui/p/<key>/admin/ws?csrf-token=<n>` | as the home socket, and the owner | the admin socket |
| `POST /ui/login` | host; `Sec-Fetch-Site`; body at most 1,024 bytes, `application/x-www-form-urlencoded`; `token` is 64 lowercase hex; it authenticates; its principal is not the owner | the enter page for a new `Home` grant with `ceiling` operator, or observer when `readonly=on` |
| `GET /ui/claim` | host; `Sec-Fetch-Site` | a fixed document with the two fields |
| `POST /ui/claim` | host; `Sec-Fetch-Site`; body at most 1,024 bytes; `token` is `loomclaim_` and 64 hex; `name` empty or valid; the claim redeems | the welcome page (below) |

The page and socket of a `Session` grant are unchanged. A `Home` and an
`Admin` grant have no session, so their `page_grant` checks the cookie,
the key and the credential, and the admin's additionally that the
principal's kind is `OwnerPrincipal`; the membership check is skipped.

`POST /ui/login` and `POST /ui/claim` take a control-class parser permit
and are refused `503` when the daemon is not `Serving`. Each refusal is
a fixed document with no echo of the request. Neither `token` is ever in a
URL, a log line or a page; both are hashed and dropped. The owner's
credential at `/ui/login` is refused `403` with the words "sign in from a
terminal with `loom ui`".

**The welcome page** of a successful claim carries, once, the credential
the daemon drew, in a `<loom-copy>` box, under `Cache-Control: no-store`
and `Referrer-Policy: no-referrer`, with the keyed path and the nonce as
the enter page carries them and a "Continue" button that runs the enter
script. It says the key is shown once and is needed only to sign in again
or to use `loom --token-file`.

### `ui.link`

```
c→s: {v:2, id, cmd:"ui.link", body:{session_id?, page:"observer"|"operator"}}
s→c: {v:2, reply_to, event:"ui.link",
      body:{path:"/ui/sessions/<id>?ticket=<t>" | "/ui/home?ticket=<t>",
            expires_in_ms:60000}}
```

Without `session_id` the daemon mints a `Home` ticket for the caller's
principal and the requested ceiling; no membership is checked, since the
home lists what the credential may see. `loom ui [--operate|--observe]
[--open]` with no `--session` sends it. The default ceiling of a home is
the design note's question 3; this draft writes `operator` unless
`--observe` is given, and leaves `loom ui --session ID` at `observer`
unless `--operate`.

### What a page may ask the daemon, by scope and role

Each is a function on `ui_socket` in the shape of `ticket_for` and
`invite_for`: every step is made afresh from the grant and the principal
the router authenticated, never from the page, and a page that has ended
asks nothing.

| Ask | Who | What the daemon does |
|---|---|---|
| `sessions()` | `Home`, any ceiling; `Session` operator page | `manager.authorized_page` with the page's digest; an observer `OneSession` page is given an empty list, as today |
| `open(id)` | operator-ceiling `Home` or `Session` page | `ticket_for` as today: membership, resident, mint with the page's ceiling and deadline, reach `Workspace` |
| `resume(id)` | operator-ceiling `Home` or `Session` page | `session_authority` must be Owner or `Participant(Operator)`; `manager.open(id)`; poll `manager.get` with `weft/poll` for at most `resume_wait_ms` (30,000) in a managed task; then as `open(id)`; the answer is dispatched as `Linked` |
| `home()` | any `Workspace` page | mint a `Home` ticket with the page's principal, ceiling and deadline |
| `create(index, name, scope)` | `Owning` `Home` page | resolve `index` against the listing this socket last drew; `name` as `valid_name`; `scope` `workspace_private` or `session_only`; key `page-<serial>-<n>`; `manager.create_scoped` with configuration `""`; then `resume(id)`; counted by `reserve_creation` (ten an hour per credential) |
| `admin()` | `Owning` `Home` page | mint an `Admin` ticket with the page's principal and deadline |
| `principals()`, `memberships(p)`, `members(s)` | `Admin` page | the three owner-only reads with the page's digest |
| `invite(s, role, name)` | `Admin` page | `reserve_invite`; `manager.administer(Invite)` as `invite_for` does, into session `s` with `name`, claim `claim_ttl_ms` (one hour); release on a refusal that made nothing |
| `set_role(s, p, role)` | `Admin` page | `reserve_invite` when `role` is operator and the current role is observer; `administer(SetRole)` |
| `revoke(s, p)`, `revoke_credentials(p)` | `Admin` page | `administer(RevokeMembership)`, `administer(RevokeMember)`; no allowance |
| `rotate(p)` | `Admin` page | `reserve_invite`; `administer(Rotate)` with a claim of one hour |

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
`loom claim --name NAME` sends it. The browser claim sends the form's
`name` field, or none when it is empty.

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

### `principals.rename` (optional, last)

```
c→s: {v:2, id, cmd:"principals.rename", body:{principal_id?, name, epoch}}
s→c: {v:2, reply_to, event:"principals.rename", body:{principal_id, name}}
```

A member may omit `principal_id` and renames itself; a member naming
another is `forbidden`. The owner may name any member. The owner's own
name is renamed the same way. Origins already admitted keep the name they
were admitted under (`core/message.gleam:33`).

### A log line

The daemon logs `daemon.session_created` with `principal_id` and
`session_id` for every creation, from the control endpoint or a page, so a
run of creations is visible in `daemon.log`. It carries no name and no
path.

### What stays as it was

- Every check on a `Session` page: host, `Sec-Fetch-Site`, `Origin`, the
  cookie under the key, the nonce, the credential, the membership, the
  gateway's re-check per frame, the Operator cap, the observer component's
  closed message type.
- The three secrets and their scopes; `HttpOnly`, `SameSite=Strict`, the
  key path, the nonce in `sessionStorage`; `Referrer-Policy: no-referrer`.
- 053's claim rules 1 to 5; the claim's digest-only storage; `/v2/claim`.
- The session page's invite control and its allowance, now shared with the
  admin page.
- A page never carries `Owner`. Every owner action a page starts runs
  through `manager.administer` or the control handler's own path with the
  page's credential digest, and the daemon decides.

## Frozen-interface impact

Part 1.6 only.

| Change | Kind |
|---|---|
| `ui.link`: `session_id` optional; the reply's `path` may be the home exchange | additive |
| New routes `/ui/home`, `/ui/p/<key>/home`, `/ui/p/<key>/home/ws`, `/ui/admin`, `/ui/p/<key>/admin`, `/ui/p/<key>/admin/ws`, `POST /ui/login`, `GET` and `POST /ui/claim` | new routes under the prefix 051 fixed |
| `credentials.claim`: optional `name` | additive |
| New owner-only read `sessions.members` | new command |
| New `principals.rename` | new command, optional |

The session protocol (Part 1.3) does not change: presence and origins
already carry the current display name. The catalogue schema does not
change. `docs/client-protocol.md` §2 (routes), §3 (`ui.link`,
`credentials.claim`, the two new commands) and the list of control
commands change to match.

Four rulings in `docs/next.md` are amended if the owner accepts: "daemon
control stays terminal-only" admits creation from an owner's operator home;
"operator surfaces do not open saved sessions" admits an operator-ceiling
page running the control command's path; "053 phase 4 waits for use" is
superseded by the admin page here; and the observer-sidebar ruling is kept
for `OneSession` pages and does not apply to `Workspace` ones, which draw
one "Home" control and no list.

## Impact

- `client/daemon/ui_sessions`: `Scope`, `Reach`, `admin_ms`, the
  per-scope page bound, `reserve_creation`.
- `client/daemon/ui_http`: the new `Route` variants and the two `POST`
  forms' body bounds.
- `client/daemon/server`: the routes, `page_grant` by scope, `ui.link`
  without a session, `sessions.members`, `principals.rename`, the welcome
  and enter documents, the log line.
- `client/daemon/ui_socket`: `resume_for`, `home_ticket_for`,
  `create_for`, `admin_ticket_for`, the admin asks; the home and admin
  sockets' admission rules.
- `client/daemon/manager`, `storage/access`: `claim` with a name;
  `members_page`; `rename` exposed.
- `host/access`, `tui`: `loom access members`, `loom claim --name`,
  `loom ui` without `--session`, `--observe`.
- `web_view`: `home`, `admin`, the "Home" control on both session pages,
  saved rows as buttons, the create form, the welcome and claim documents
  in `page`, endings for a home and an admin page.
- `web_client`: `switch_rule` accepting the home exchange shape; the
  welcome page's Continue.
- `docs/architecture/web-view.md`, `multiplayer.md`, `daemon.md`,
  `docs/next.md`: the rulings and the new pages.

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
  home, session, home ends at the first home's deadline.
- `resume` opens a saved session the principal operates and lands on it;
  refuses an observer membership, a `Reserved` and a `RecoveryBlocked`
  row, and an open that outlasts `resume_wait_ms`, each with its fixed
  words and no ticket; a second press while one is out asks nothing.
- `create` makes a session in a listed workspace with the typed name and
  scope and lands on it; refuses an index outside the listing, an invalid
  name, the eleventh creation in an hour; a repeated press makes one.
- The admin page ends at fifteen minutes and the home does not; every
  grant action counts against the allowance shared with the session page,
  a demotion and a revocation do not; a member's `sessions.members` is
  `forbidden`; no frame on the admin socket carries `loomclaim_` but the
  one that shows the owner their invitation.
- A claim with a `name` binds and the first attach's presence row carries
  it; an invalid name binds nothing and the claim stays open; `loom claim
  --name` sends it.
- `POST /ui/claim` binds a daemon-drawn credential, applies the name, and
  lands on an operator home; the credential appears in exactly one response
  and in no file under the state root; a spent, void, expired or
  otherwise-bound claim is refused in fixed words.
- `POST /ui/login` lands on a home at the chosen ceiling; the owner's
  credential is refused; a cross-site `POST` is refused at both forms; a
  claim-shaped value at login and a bearer-shaped value at claim are
  refused before any lookup; bodies over 1,024 bytes are refused.
- Mutations, each applied alone and reverted, each fail a named test: a
  member's home offered the Admin button; the admin exchange accepting a
  `Home` ticket; `reserve_invite` skipped for a promotion; `create`
  accepting a path; `resume` skipping the authority check; the welcome page
  served with a cacheable header; `/ui/login` accepting the owner.

## Cost

- **Two forms that take a secret in a browser.** A credential and a claim
  typed into a loopback page can be read by whatever reads the browser's
  form history. The owner's credential is kept out of it; a member's is
  theirs to keep.
- **A stolen owner home is worth more than a stolen owner session page**:
  sessions in known workspaces (ten an hour) and fifteen minutes of the
  admin page, whose grants are bounded by the same three an hour. The
  durable worst case is 051's, now for any session rather than one.
- **A lost welcome page loses the credential**, and the owner rotates.
- **A page starts runtimes.** `resume` and `create` consume registry
  capacity at a browser's request, within the bounds a terminal's open has.
- **Two more page kinds, two more components, two more sockets to review**,
  and a scope on every grant where there was a session ID.
- **The home reads the catalogue every thirty seconds per open home**, as
  the sidebar does per operator page.
- **Remote access is still 052's.** Until it lands, the claim and sign-in
  forms work on the daemon's host or through `ssh -L`, and the invitation
  the admin page shows names a loopback address.

## Decision

**Draft.** A session-less home page, an owner's admin page, a browser
sign-in and a browser claim, all under 051's ticket, cookie, key and nonce,
with the grant's one session replaced by a scope and a reach. An owner's
operator home creates sessions in workspaces the owner already has sessions
in, and any operator-ceiling page opens a saved session through the control
command's own checks. The admin page grants under the session page's
allowance and reduces freely. The invitee's name is a field on the claim.
A browser credential kind, a free path field, an unbounded admin page and
a long-lived cookie were considered and not taken. The design note's
thirteen questions are the owner's; this draft is accepted or amended when
they are answered.

## Open

- **052.** A `Remote(origin)` request should admit `Home` and `Session`
  pages and never `Admin` or the create control; the claim address the
  admin page shows needs the proxy's origin, which is 052's `--ui-origin`.
- **`loom access page`** from 053 phase 4, unbuilt; the home's button
  covers it.
- **Stop from the browser.** One fixed button per running session on the
  owner's home, through `administer`, if asked for.
- **A longer home for browser claimants**, if the daily sign-in proves too
  much (the design note's question 2).
