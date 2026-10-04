# The web view's workspace mode: a home, new sessions, an admin page and a chosen name

**Status: proposed, for the owner's review.** This note answers the owner's
request of 2026-10-03 for the web UI: "a mode where I can use it like a
traditional system, so: make sessions, switch between them, admin interface
where I can invite ppl to read/write sessions, when a multiplayer then they
can choose an identifier". It says what the tree already has, what is new,
why each new piece is shaped the way it is, what it costs a stolen page, and
the order to build it in. The wire and route changes it needs are drafted in
[protocol-change/065](../../protocol-change/065-web-workspace-mode.md); this
note is the reasoning and the plan, 065 is the rule.

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

Several things the request asks for were ruled against earlier, each for a
reason that still holds in part. Section 9 lists them as questions, with the
recommended answer. Nothing in this note is settled until the owner answers
them.

## 0. The shape in short

Today a browser reaches exactly one session's page through a 60 second
ticket that `loom ui --session ID` mints; the page's cookie, key and nonce
name that one session and nothing else. This note adds two more kinds of
page under the same ticket, cookie, key and nonce machinery, and changes
nothing about how a session page is admitted:

- **A home page**, not bound to a session, that lists the sessions the
  principal holds, grouped by workspace, and opens any of them. It is the
  app's front door: the sidebar the session page already draws becomes the
  navigation of the whole app, and every session page opened from a home
  can get back to it. The owner's home also creates sessions and opens the
  admin page.
- **An admin page**, for the owner only, fifteen minutes long, that lists
  principals and memberships, invites per session with a role, changes a
  role, revokes a membership or a credential, and rotates a credential. It
  is 053's phase 4 page, with the grants the owner has since asked for, and
  bounded the way the session page's invite control already is.

Two things let a person into the home: their own `loom ui` (as today, now
without `--session`), or, for a person with no `loom`, a browser sign-in
form that takes their credential once, and a browser claim form that
redeems an invitation, takes the name they want to be shown under, and
signs them in. The browser never keeps a credential; it keeps a cookie that
lives eight hours, as every page does today.

The invitee's name is a label on an authenticated principal and nothing
more: it is set when the claim binds, it goes into presence rows and
authorship exactly as the inviter's choice does today, and it changes no
check anywhere.

## 1. The home page and how a browser gets into it

### 1.1 What exists

A UI session is a `Grant` (`ui_sessions.gleam:127`) of one session, one
credential digest, one principal and one ceiling, kept with the digests of
the page's cookie, key and nonce in one actor. A ticket for it is minted
only by `UiLink` (`client/daemon/server.gleam:1534`) over the principal's own
control connection, after `session_authority`
(`client/daemon/manager.gleam:936`) finds a membership, and by a page
switching to another session (`ticket_for` (`ui_socket.gleam:735`)). The
exchange redeems it once (`redeem` (`ui_sessions.gleam:367`)), the page and
its socket are re-authorized on every request (`page_grant`
(`client/daemon/server.gleam:356`)), and every route is checked in 051's
order: `loopback_host` (`ui_http.gleam:138`), then `navigation_allowed`
(`ui_http.gleam:202`) for a page, `origin_matches` (`ui_http.gleam:217`) for
the socket, then the cookie under the key. The cookie's `Path` is the key's
(`set_cookie` (`ui_http.gleam:265`)), so it reaches no other page and no other
loopback port. A UI session lives eight hours (`session_ms`
(`ui_sessions.gleam:79`)); a chain of switches ends with the page it began
from (`mint_before` (`ui_sessions.gleam:306`)).

The operator page already lists the principal's sessions in a sidebar,
read with the page's credential digest (`listed_for`
(`ui_socket.gleam:663`), `authorized_page`
(`client/daemon/manager.gleam:1263`)), grouped by workspace (`grouped`
(`web_view/sessions.gleam:154`)), and a row for a running session is a button
that mints a ticket and navigates (`view` (`web_view/view/sidebar.gleam:63`),
`target` (`web_client/switch_rule.gleam:40`)). The observer page has no
sidebar, by ruling (051, the addendum on the session sidebar): an observer
link is the one a person hands to someone who may only watch one session.

There is no page without a session, no route a browser can present a
credential to, and no way for a page to learn where it came from.

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

### 1.3 Three ways into a home

**`loom ui [--operate] [--open]` with no `--session`.** `run_view` resolves
the daemon as it does today (`view_request` (`tui.gleam:1122`)) and sends
`ui.link` with no `session_id`. The daemon mints a `Home` ticket with the
caller's principal and the requested ceiling, and `loom` prints or opens
`/ui/home?ticket=<t>`. This is the owner's path, and the path of any member
who has `loom`. The owner token never reaches a browser.

**`POST /ui/login`**, for a person with a credential and no `loom`. The
form carries the credential and a "read-only" checkbox. The daemon checks
the host and `Sec-Fetch-Site` as it checks the exchange, authenticates the
credential (`authenticate` (`client/daemon/manager.gleam:913`)), mints and
redeems a `Home` ticket in one step, and answers the enter page with the
cookie, key and nonce, exactly as the exchange does. The credential is read
from the form body, hashed, and dropped; it is never in a URL, a log or a
page. The owner's credential is refused here (question 11): the owner has
`loom ui`, and the owner token should not sit in a browser's form history
or password manager.

**`POST /ui/claim`**, for an invitee with no `loom` (section 5.3). It
redeems the claim, binds a credential the daemon draws, applies the chosen
name, and signs the person in as `/ui/login` would.

A browser therefore holds, at most, an eight hour cookie; what it typed
into a form was hashed and forgotten. Renewing a home costs one `loom ui`
or one sign-in. A longer-lived "remember me" cookie was considered and is
not proposed (question 1): 051 chose eight hours so that a cookie copied out
of a browser profile stops working the same day, and a sign-in form makes
renewal cheap enough that the bound can stay.

### 1.4 Routes and checks

| Route | Check order | Answer |
|---|---|---|
| `GET /ui/home?ticket=<t>` | host, `Sec-Fetch-Site` none or same-origin, redeem a `Home` ticket | the enter page; cookie `Path=/ui/p/<key>`; nonce in the body |
| `GET /ui/p/<key>/home` | host, `Sec-Fetch-Site`, cookie under the key, credential authenticates | the shell for the home |
| `GET /ui/p/<key>/home/ws?csrf-token=<n>` | host, `Origin`, nonce, cookie, credential | the home socket |
| `POST /ui/login` | host, `Sec-Fetch-Site`, body at most 1 KiB, credential authenticates, not the owner | the enter page for a new `Home` grant |
| `GET /ui/claim` | host, `Sec-Fetch-Site` | the claim form, a fixed document |
| `POST /ui/claim` | host, `Sec-Fetch-Site`, body at most 1 KiB, claim redeems | the welcome page (section 5.3) |

A `Home` ticket presented at a session's exchange, or a session ticket at
the home's, is spent and refused, as `OtherSession` (`ui_sessions.gleam:184`)
spends one presented against the wrong session today. The scope is part of
the redemption, in the same actor message, so the property 053 wanted from a
separate admin ticket table (a session ticket never redeems at the admin
exchange) holds with one table.

A home's `page_grant` checks the cookie, the key and the credential and
skips the membership check, since there is no session; everything the home
then shows is read with that credential digest and is what the principal is
entitled to see.

### 1.5 What the home draws

The home is the A2 shell (`view` (`web_view/view/shell.gleam:91`)) with the
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
   decides whether it can be shared). The owner's centre also holds the
   create form and an "Admin" button. A member's centre holds the table.
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

### 1.6 Security

The threat model is 051's: the session's agent reaches the loopback
listener unless `--network off`, browsers send cookies to every port of a
host, and a page stands on a cookie, a key and a nonce. The home adds these
cases.

- **A stolen home page** (all three secrets, by a profile read) is worth,
  for a member, the list of their sessions and an operator page on any
  running one they operate, for up to eight hours: that is what a stolen
  operator page is already worth after the switching addendum. For the
  owner it is worth more: a session in any known workspace (section 2) and
  fifteen minutes of the admin page (section 4), each bounded below. The
  defences are unchanged: `HttpOnly`, `SameSite=Strict`, the key path, the
  nonce in `sessionStorage`, the eight hours, and revocation of the
  credential, which ends every page it minted.
- **CSRF.** The home's actions are Lustre events over its socket, which
  needs the nonce and an exact `Origin`; no action is an HTTP request a
  cross-site page could make the browser send. The two HTTP `POST`s,
  `/ui/login` and `/ui/claim`, are refused unless `Sec-Fetch-Site` is
  `none` or `same-origin`, and each needs a secret the attacker lacks. A
  login-CSRF, where an attacker signs the victim into the attacker's own
  principal so the victim's prompts land in the attacker's sessions, is
  refused by `Sec-Fetch-Site`, and would in any case produce a page whose
  top bar names the attacker's principal.
- **A hostile page on another loopback port** receives the cookie for a
  path holding the key, as today, and nothing else; the home's socket needs
  the nonce it cannot read. The `Referrer-Policy: no-referrer` that keeps
  the key out of `Referer` covers the home's URLs too.
- **An observer escalating.** An observer-ceiling home mints only observer
  tickets (`mint_before` carries the page's ceiling). It cannot open a saved
  session (section 3), create one, or reach the admin page: each is refused
  by the daemon from the grant it holds, whatever the socket forwarded, and
  the home component's observer variant has no message that asks.
- **A sign-in form on loopback.** A bearer typed into a form on a page
  served from `127.0.0.1` can be read by any process that can read the
  browser's form history or a password manager's store. That is the
  person's choice to make and the reason the owner's credential is refused
  there. The form has `autocomplete="off"`, which password managers ignore;
  the note does not pretend otherwise.

### 1.7 Left out of the home

- A longer login. Eight hours, renewed by `loom ui` or a sign-in.
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
`create_scoped` (`client/daemon/manager.gleam:1037`) under an idempotency key.
The terminal builds that key from its own identity, the wall clock and a
counter (`CreateSession` (`tui/session_control.gleam:672`)), names the session
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
   created in from the browser is one the owner already has a session in;
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
on it is in the list. Question 6 asks the owner to confirm leaving the path
field out.

### 2.4 Security

A stolen owner home can create sessions in known workspaces, bounded by
the registry's capacity and `max_pages`, and prompt them at operator role.
That is a new agent in a workspace the owner already runs agents in, at
the sandbox policy that workspace's registrations carry. It can fill the
catalogue with sessions; a count per credential per hour, as
`reserve_invite` (`ui_sessions.gleam:332`) keeps for invitations, bounds it
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
(`reason_words` (`web_view/sessions.gleam:122`)). The ruling "operator
surfaces do not open saved sessions" was about the listing not being
permission to activate; the open must go through the membership- and
epoch-checked path.

### 3.2 What is new

Switching becomes the app's navigation: every page with `Workspace` reach
has a "Home" control, the home opens any listed session, and an
operator-ceiling page opens a saved session.

**Opening a saved session** (`ui_socket.resume_for`) is the control
command's path, run on the page's behalf with the page's credential digest
and the epoch the page was admitted in:

1. the page is open and its ceiling is Operator;
2. `session_authority` finds Owner or Operator authority in the target: an
   observer member is refused with the words "ask an operator to resume
   it", the check `OpenSession` (`client/daemon/server.gleam:1630`) makes;
3. `open` (`client/daemon/manager.gleam:991`) is called, which is the same
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
shape, `/ui/home?ticket=<64 hex>`, and nothing else new.

### 3.3 What changes in the ruling

A page opening a saved session is the daemon starting a runtime at a
browser's request, which the switching addendum said the rulings did not
include. The request asks for it, and the path proposed is the control
command's own, with the same authority and epoch checks, so the listing is
still not permission: the membership is. Question 4 asks the owner to lift
the ruling for operator-ceiling pages.

## 4. The admin page

### 4.1 What exists

053 designed the admin page in full (phase 4) and the owner ruled on
2026-09-30 that it waits for use of the terminal's `/access` overlay
(`tui/access_overlay.gleam`). The daemon serves the two owner-only reads it
needs, `principal_page` (`client/daemon/manager.gleam:800`) and
`membership_page` (`client/daemon/manager.gleam:823`), and every mutation
through one dispatch, `administer` (`client/daemon/manager.gleam:648`): invite,
set-role, revoke membership, rotate, revoke credentials, isolate. The owner's
session page already starts one of those from a browser, `invite_for`
(`ui_socket.gleam:812`), bounded to three an hour for the credential and shown
once. `loom access` has the whole grammar (`usage` (`host/access.gleam:169`)).

What is missing: a per-session list of members (the listing is per
principal), any grant other than the session page's invite from a browser,
and the page itself.

### 4.2 What is new

The admin page is its own page kind, scope `Admin`, minted only from an
`Owning` home by pressing "Admin" (`ui_socket.admin_ticket_for`) and living
fifteen minutes from its exchange. The owner's home is unaffected when it
ends; pressing "Admin" again mints another. `loom access page`, which 053
proposed, is not built here; the home's button covers it.

It draws, from `principals.list`, `principals.memberships` and the new
`sessions.members` (065):

- **Principals**: name, ID, kind, credential state (`active` with its
  fingerprint and `claimed_at_ms`, `claim_open` with the time left,
  `claim_expired`, `none`). An open claim is a pending invitation; the page
  lists them under that heading too.
- **Per session**: the members and their roles, and the session's domain
  scope, so the owner sees before inviting whether the session must be
  isolated first.

And it does, each through `administer` with the page's credential digest,
which authenticates the owner and the epoch again in the registry's own
dispatch:

| Action | Fields the form has | Bound |
|---|---|---|
| Invite to a session | role (observer or operator), name | the credential's claim allowance (three an hour, shared with the session page's control); the claim lives an hour |
| Set role | role | the allowance when the role rises to operator; none when it falls |
| Revoke membership | none, two-step button | none; it reduces |
| Revoke credentials | none, two-step button | none; it reduces |
| Rotate | none | the allowance; the claim lives an hour |

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

- Own flag (`--ui-admin`): dropped. The session page already grants from
  the browser without one, and the admin page is minted only from an
  owner's operator home, which exists only for an owner who ran `loom ui
  --operate` or signed in; question 8 asks whether to keep the flag anyway.
- Loopback only: kept. Under 052, a `Remote(origin)` request never mints
  or admits an `Admin` or `Home`-with-creation page; a remote owner uses
  `ssh -L`.
- Minted only for the owner: kept, by the grant and by `administer`.
- Fifteen minutes: kept.
- Reduce-only: not kept, by the owner's request. The 051 invite addendum
  already prices a page that grants; the admin page's grants are held to
  the same count, and `set-role` to operator counts as a grant.
- No path to a grant: see the line above.
- No session content: kept. The admin page draws names, IDs, roles and
  states, all catalogue fields.
- Own ticket kind, cookie path and lifetime: kept, by `Scope.Admin` in the
  one table and the key-scoped cookie path.

A stolen admin page (its three secrets, inside its fifteen minutes) can
revoke every member and credential (a denial of service the owner repairs
by inviting again), read the principal list, and mint three claims an hour
for the credential, each a membership that outlives the page until revoked.
That last is the case 053 named and the owner accepted for the session page
on 2026-09-30; the admin page widens it from the page's own session to any
session, which is what "invite people to sessions" asks for. The page
cannot reach the owner token, cannot change who the owner is, and cannot
grant Owner.

## 5. The invitee chooses a name

### 5.1 What exists

A principal has a stable ID and a display name (`Principal`
(`storage/access.gleam:202`)), set by the inviter (`loomd access invite
SESSION PRINCIPAL ROLE NAME`, and `Guest <digits>` from the page). The
catalogue can rename one (`rename` (`storage/access.gleam:861`)) and no control
command exposes it (053, Open). A claim binds a credential to the principal
(`claim` (`client/daemon/manager.gleam:677`)) and carries no name. The name
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
cannot see is taken, and would mean nothing for authority (question 9).

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
   lookup, and `claim_known` (`client/daemon/manager.gleam:701`) must find
   it open;
3. the daemon draws a 32-byte credential from `token.production_entropy`
   (the source every secret here uses), and binds its digest with
   `manager.claim`, with the name. This is 053's option B, the daemon
   minting, chosen for the browser because the browser has no private file
   to store a credential in before sending its digest, which was the whole
   argument for option C in `loom claim`;
4. it mints and redeems a `Home` ticket for the new credential at Operator
   ceiling;
5. it answers a welcome page: "You're in as NAME. This is your sign-in key;
   it is shown once. Save it somewhere private: [copy box]. Continue." The
   credential is in that one response body, under `no-store` and
   `no-referrer`, and the Continue button runs the enter script that stores
   the nonce and moves to the home. Without the key the person is still
   signed in for eight hours; they need it only to sign in again at
   `/ui/login` or to use `loom --token-file`.

A lost welcome page loses the credential, as 053 said of option B; the
owner rotates, which voids the credential and issues a new claim, and the
listing shows `claimed_at_ms` so the owner can see a claim was redeemed by
someone. The refusals are 053's, in fixed words: unknown or void, expired,
bound to another credential (`conflict`), and a bad name, which binds
nothing.

Question 2 offers the alternative: never show a credential, and give a
browser claimant a thirty-day home cookie instead. It is simpler to use and
costs a stolen cookie thirty days instead of eight hours. This note
recommends the key shown once, because it keeps one credential model and
051's lifetime.

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
| `ui.link`: `session_id` optional; absent means a `Home` ticket | additive |
| New `/ui` routes: `/ui/home`, `/ui/p/<key>/home`, `/ui/p/<key>/home/ws`, `/ui/admin`, `/ui/p/<key>/admin`, `/ui/p/<key>/admin/ws`, `POST /ui/login`, `GET` and `POST /ui/claim` | new routes under 051's prefix |
| `credentials.claim`: optional `name` | additive |
| New owner-only read `sessions.members` | new command |
| New `principals.rename` (optional, last PR) | new command |

No session-protocol frame changes. No catalogue schema change: the name is
the existing `display_name` column, and the per-session members read is a
new query over the existing tables (`make gen-sql`).

## 7. The pull requests

Each lands alone, leaves `make check` green and `make doc-check` clean, and
is reviewed by a Fable advisor pass before the queue. Each names its tests;
the route tests run on a real listener and registry as `ui_route_test` does
today, and the component tests through `lustre/dev/simulate`. Workers read
051's addenda on switching and inviting first: the shape of every new
daemon-side function is `ticket_for` or `invite_for`, and the shape of every
new control is the invite control.

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
with and without `--session`.

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
`Creating` message; `create_for`; the creation allowance in `ui_sessions`.
Exit: the owner's operator home creates a session in a listed workspace
with the typed name and lands on it; a member's home draws no control and
the daemon refuses a forged submit; an index outside the listing is
refused; an invalid name is refused and nothing is created; the eleventh
creation in an hour is refused; a repeated press creates once. Tests:
`ui_route_test` (create and land, the member refusal, the index refusal,
the allowance), `home_test` (the form's decoder is total, the control's
paths, text only), `ui_sessions_test` (the allowance).

**PR 5: `sessions.members` and the admin page.** The read, its SQL,
`loom access members SESSION`; `Scope.Admin` with its fifteen minutes; the
"Admin" button; `web_view/admin` with the lists and the five actions; the
grant allowance shared with the session page's invite. Exit: the owner's
home opens an admin page that lists principals, pending claims and a
session's members; each action changes the catalogue and the page re-reads;
a member's `sessions.members` is `forbidden`; the admin page ends at
fifteen minutes and the home does not; a session ticket never redeems at
the admin exchange; the fourth grant in an hour across the admin page and a
session page is refused; a demotion costs no allowance; no frame on the
admin socket carries `loomclaim_` except the one that shows it to the owner.
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

**PR 7: the browser claim and sign-in.** `GET` and `POST /ui/claim`, the
welcome page, `POST /ui/login`. Exit: an invitee with no `loom` redeems a
claim in the browser, chooses a name, is shown the key once, and lands on
an operator home; signing in with that key later lands on a home; the
read-only box lands on an observer-ceiling home; the owner's credential is
refused at sign-in; a cross-site `POST` is refused at both; a claim-shaped
value at sign-in and a bearer at the claim are refused before any lookup;
the credential appears in exactly one response and under no file in the
state root. Tests: `ui_route_test` for every refusal and the one success
of each form, `page_test` for the two fixed documents and their headers,
a state-root scan as `the_claim_redeems_and_only_its_digest_is_kept_test`
does today.

**PR 8, optional: `principals.rename`** and a "Your name" control on the
home for members; the owner renames anyone from the admin page.

PRs 1 to 4 are a chain. PR 5 needs PR 1. PR 6 is independent. PR 7 needs
PRs 1 and 6. PR 8 needs PR 5.

## 8. What this note leaves out, and why

- **Remote access.** 052 is a proposal. The browser claim and sign-in make
  it more useful, since they are what a teammate with no `loom` needs, and
  065 says which of its answers 052 must keep (`Admin` and creation stay
  loopback).
- **A free workspace path field.** Section 2.3.
- **A longer login or a remember-me cookie.** Section 1.3; question 1.
- **Stop, delete, rename, archive from the browser.** Section 1.7.
- **Per-session member lists on the session page.** The Session pane shows
  viewers; members with roles are the admin page's.
- **A composer target menu, Goals and Jobs pages, activity badges.** As the
  design note left them.
- **`loom access page`.** The home's button replaces it; 053's phase 4
  command stays unbuilt.
- **Uniqueness of names, name moderation.** Section 5.2.

## 9. Questions for the owner, with recommendations

1. **How long does a browser login last?** Recommended: eight hours, as
   every page today, renewed by `loom ui` or by the sign-in form. A longer
   cookie trades 051's "stops working the same day" for convenience.
2. **How does a browser-only invitee get a credential?** Recommended: the
   daemon mints it at the browser claim and shows it once as a sign-in key
   (053's option B, applied where option C cannot work). Alternative: show
   nothing and give the claimant a thirty-day home cookie; simpler, and a
   stolen cookie is worth thirty days.
3. **The default ceiling of a home.** Recommended: a home minted by `loom
   ui` without `--session` is an operator's unless `--observe`, because a
   home link is for oneself and the request is a read-write mode; `loom ui
   --session ID` keeps its observer default, because that is the link one
   hands out. The sign-in form defaults to operator with a read-only box.
   Alternative: keep observer-by-default everywhere and require `--operate`.
4. **May an operator-ceiling page open a saved session?** Recommended: yes,
   through the control command's own checks (section 3). This lifts the
   ruling "operator surfaces do not open saved sessions" for pages whose
   principal holds Operator or Owner authority on the target.
5. **Default domain scope for a session created from the browser.**
   Recommended: `workspace_private`, the terminal's default, with a
   "shareable" box that makes it `session_only`. Alternative:
   `session_only` always, since the browser is where sharing happens; it
   costs the new session the workspace's memory.
6. **No free path field.** Recommended: confirm. A session in a new
   workspace is created from a terminal once.
7. **A home lists the principal's sessions at any ceiling.** Recommended:
   yes. The observer ruling was about handed-out session links, which
   `Reach.OneSession` keeps exactly as they are.
8. **Does the admin page need `--ui-admin`?** Recommended: no. It is minted
   only from an owner's operator home, and the session page already grants
   without a flag. Keep it if the owner wants a daemon that serves the web
   view but can never administer from it.
9. **Are display names unique?** Recommended: no; the ID is the identity
   and every surface shows the short ID beside the name.
10. **Self-rename later** (`principals.rename`, PR 8). Recommended: build it
    last, only if the claim-time name is not enough.
11. **The owner's credential at `/ui/login`.** Recommended: refuse it; the
    owner uses `loom ui`. Accepting it puts the owner token in a browser's
    form history.
12. **The grant allowance counts `set-role` to operator.** Recommended: yes;
    a promotion is a grant a stolen admin page could make. A demotion is
    free.
13. **Build order.** Recommended: as section 7, with PR 3 (opening saved
    sessions) before PR 4 (creation) so a created session can be opened.
    If question 4 is answered no, PR 4 lands without landing on the new
    session, and the row appears as saved.
