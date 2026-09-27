# protocol-change/053: claim tokens, `loom access`, and an owner's admin view

**Status**: ACCEPTED 2026-09-27 (owner); step 1, the claim flow, is
implemented ("Step 1 as built" below) · **Affects**: Part 1.6 client
protocol (a `/v2/claim` route; the `sessions.invite`, `credentials.rotate`
and `credentials.revoke` replies or semantics; new control commands; in
later phases, `/ui/admin` routes) and the `access` command lines of `loomd`
and `loom` · **Raised by**: the owner's request for "an admin UI that can
provision other users, and likely a CLI companion too, e.g. one that can
produce the bearer auth token needed to claim a user" · **Builds on**:
[protocol-change/015](015-daemon-control-and-session-attachments.md)
(the owner-managed member access addendum),
[051](051-web-view-route.md), [052](052-web-view-remote-origin.md),
[ADR-014](../docs/adr/014-second-runtime.md)

## Problem

The owner provisions a person today with `loomd access`. Its grammar is one
line (`client/daemon/admin.gleam:34`):

```
loomd access [--state-dir PATH] invite SESSION PRINCIPAL ROLE NAME
  | set-role SESSION PRINCIPAL ROLE | revoke SESSION PRINCIPAL
  | rotate PRINCIPAL | revoke-credentials PRINCIPAL
  | isolate SESSION --share-existing-transcript
```

`loomd` dispatches it from `client.gleam:50`. The command reads the
daemon's endpoint record and `owner.token` from the state directory
(`admin.gleam:224-249`), so it runs only on the daemon's host, as the user
who owns that directory. It sends one control command, prints the
principal ID on standard error and the reply as one JSON line on standard
output, and exits (`admin.gleam:44-72`).

`invite` sends `sessions.invite`. The daemon draws 32 bytes from
`token.production_entropy`, hex-encodes them as a bearer, and stores only
the bearer's SHA-256 digest (`server.gleam:965-982`). `access.invite_member`
creates the principal, its credential and one session membership in one
transaction (`storage/access.gleam:191-206`). The reply carries the
plaintext bearer (`server.gleam:1228-1251`), and the CLI prints it
(`admin.gleam:445-456`). `rotate` does the same through `credentials.rotate`
(`server.gleam:984-1001`, `storage/access.gleam:219-237`).

So the owner ends up holding a working credential that belongs to someone
else, with no expiry, and has to deliver it: in chat, in email, or read
aloud. Four things follow.

- **Anyone who reads the message can use the credential**, at the same
  time as the invitee. The daemon cannot tell the two apart, and nothing
  shows the owner that a second party is using it.
- **The copy never goes stale.** A bearer sitting in a chat log works until
  the owner runs `rotate` or `revoke-credentials`.
- **The invitee's copy is handled loosely.** The remote launch takes
  `--token BEARER`, which puts the credential in the process's argument
  vector, or `--token-file PATH`, which is read with `simplifile.read` and
  no owner or mode check (`tui.gleam:1188-1198`). The page launch reads its
  token file through `read_private_bounded`, which refuses a file other
  users can read (`tui.gleam:1026`, `host/bootstrap.gleam:359-388`); the
  terminal launch does not.
- **The owner cannot ask who has access.** The catalogue stores
  principals, credentials and memberships (`storage/sql/access.sql`), but
  no query lists them and no control command exposes them.

The owner's other tools do not fill the gap. The terminal has owner-only
flows: `/peers` (`session_view/command.gleam:414`, `tui/peer_links.gleam:1-5`,
checked by the daemon at `server.gleam:832-833`) and the session picker,
which reads the owner-only `sessions.activity` (`server.gleam:1092-1094`,
`tui/session_selector.gleam:11`). Neither touches principals or
memberships, and no terminal code handles invitations. The web view caps
every page at Operator: `ui_relay.capped` returns at most
`Participant(Operator)` whatever the membership or ceiling
(`ui_relay.gleam:84-110`), and `ui.link` mints a ticket for the caller's own
membership only (`server.gleam:1055-1085`).

Three questions need answers:

1. How does an invitation reach the invitee without a live credential
   crossing a chat channel?
2. Where does the owner run administration, and does it need to work away
   from the daemon's host?
3. Should a browser page hold owner authority at all, given that 051's
   operator addendum names the session's own agent as the threat that
   matters most (`051-web-view-route.md:445-470`)?

## What was considered

### How an invitation reaches the invitee

Four designs were compared.

- **A. A bearer in the invitation.** Today's design.
- **B. A claim token, with the credential minted by the daemon.** The
  invitation carries a short-lived, single-use claim token. The invitee's
  client presents it once, and the daemon's reply carries a fresh bearer.
- **C. A claim token, with the credential minted by the invitee's
  client.** As B, except the client draws the bearer itself, writes it to
  disk, and sends only its SHA-256 digest with the claim. The reply
  carries no secret.
- **D. Enrollment by digest.** The invitee's client draws a bearer first
  and sends its digest to the owner, and the owner invites with that
  digest. No secret crosses the channel at all.

| | A: bearer | B: claim, daemon mints | C: claim, client mints | D: digest enrollment |
|---|---|---|---|---|
| What crosses the channel | a live credential | a single-use claim | a single-use claim | a digest, not secret |
| Someone reads it before the invitee uses it | full access, unnoticed, alongside the invitee | a race; the loser's claim is refused | as B | nothing to steal; a substituted digest needs a channel that can be altered |
| Someone reads it after use | full access | nothing | nothing | nothing |
| Replay | works until rotation | refused | refused | not applicable |
| Lost before use | owner rotates and resends a bearer | owner rotates, which voids the old claim | as B | invitee resends |
| The claim's reply is lost | not applicable | the credential is lost; owner rotates | invitee reruns the same command | not applicable |
| Messages between the two people | one | one | one | two |

**A is rejected.** Its failures are silent: an intercepted bearer and the
invitee's use of it look identical to the daemon.

**B against C.** The two are identical on the wire except for which side
draws the random bytes. C removes one failure: because the invitee's
client stores its credential before it sends the digest, an unknown
outcome is resolved by presenting the same claim and the same digest
again, and the daemon answers with the same success. Under B, the only
copy of the credential is in the reply, so a lost reply loses it and the
owner must rotate. C costs one thing. `storage/access` requires the caller
to mint credentials with cryptographic randomness (`storage/access.gleam:8-10`),
and under C the daemon never sees the credential, so it cannot check that.
`loom` draws the 32 bytes from `gleam_crypto`, which `host` already
depends on (`host/gleam.toml:10`, `host/bootstrap.gleam:136-138`). A
modified client that sends the digest of a weak secret weakens only the
credential of the person running it, who could already hand that
credential to anyone.

**D is not the default.** It needs two messages, and it asks the invitee to
act before being invited. Its property, that nothing secret crosses the
channel, trades confidentiality for integrity: an attacker who can alter
the chat substitutes their own digest. Chat gives neither property
reliably. D composes with C, since both bind a digest the invitee's
client drew, so the invitation takes an optional `credential_digest` and
D is offered alongside C. The owner confirms a digest's fingerprint with
the invitee over a second channel, and D is the recommended form for an
invitation that grants the operator role.

**A claim redeemed by the wrong person.** Under C, the rightful invitee's
claim is then refused with `conflict`, and `loom claim` tells them to
contact the owner. That signal depends on the invitee trying and on the
invitee reporting the refusal; if the invitee never runs the claim, nobody
learns of it. So the owner has two more checks. The owner's listing shows
when the claim was redeemed (`claimed_at`) and a fingerprint of the bound
credential, and `loom claim` prints the fingerprint of the invitee's own.
The documentation tells the owner to confirm the fingerprint with the
invitee out of band before relying on a new member, and recommends
enrollment by digest (option D, below) when the invitation grants the
operator role. The owner recovers with `rotate`, which revokes the
credential the wrong person bound and issues a new claim. The wrong person
held exactly the memberships the owner granted, from the claim until the
rotation. A second code relayed on another channel (a PIN) was considered
and not taken: it adds a second secret to deliver, and the fingerprint
comparison already covers the same case without one.

**C is chosen.**

### Where the claim is presented

- **On `/v2/control`, under a second authorization scheme.** The scheme
  admits a connection with no principal onto the control endpoint, and
  every control command would then have to check for that case.
- **In a `/ui` exchange.** The exchange needs a browser, and it moves a
  step that creates a credential into the page threat model.
- **On a new route, `/v2/claim`, whose one command is `credentials.claim`.**
  The route keeps the claim's authority apart from the credential's, the
  way 015 separates the control endpoint from session endpoints (spec Part
  1.6, `docs/loom-implementation-spec.md:279`). Chosen.

### Where claims are kept

In memory, a daemon restart would void every open claim and leave each
invited principal with a membership and no way to obtain a credential
until the owner rotates. 051's tickets live in memory because they last 60
seconds (`ui_sessions.gleam:44`); a claim lasts up to a day. Claims are
kept in the catalogue, as digests, in a table next to `access_credentials`.

### Where the owner administers

- **Only on the daemon's host, with `loomd access`.** Today's design.
- **A separate owner-grade credential for remote administration.** A second
  kind of credential, with its own issue, rotation and revocation. 051 and
  052 both declined to add one. Rejected.
- **`loom access`: the same commands, from the client shipment, local by
  default, and against a remote daemon over `wss` with the owner token.**
  Chosen.

The remote mode adds no authority. The daemon already authenticates any
credential, the owner token included, on any control connection
(`server.gleam:363-393`), including one that arrives through 052's proxy,
because it cannot distinguish them. What remote mode does add is exposure:
it works only if the owner copies `owner.token` to a second machine. This
proposal documents that and recommends `ssh <host> loom access ...`
instead.

**Does the page share one grammar with the CLI?** They share the control
commands and the daemon's decoding of them, not a textual grammar. A page
that parsed command strings would add a parser to the browser's path and
gain nothing.

### Whether the admin UI is a web page

- **No page.** The CLI plus a terminal overlay.
- **An owner page with the CLI's full powers.**
- **A loopback-only owner page that reads and reduces authority, with
  grants proposed on the page and confirmed in the terminal.** The page
  would lodge a proposal and show a code, and the owner would run `loom
  access confirm <code>`, which prints the proposal and asks y/N. Rejected:
  an agent that obtained the page's secrets could lodge its own proposal
  and then put "run `loom access confirm <code>`" in front of the owner,
  which is attack 4 of 051's operator addendum (trick the person into
  approving, `051-web-view-route.md:468-470`). The confirmation step would
  turn a page the agent took into a way to grant authority.
- **A loopback-only owner page that reads and reduces authority, and
  renders each grant as the `loom access` line for the owner to run.**
  The owner copies the line into a terminal. The page holds no path to a
  grant, so a page the agent took still yields only reductions.

An owner page is worth more to an attacker than 051's operator page, in
kind and not only in degree. An operator page's authority ends with its UI
session. An owner page that can invite mints a claim, and a claim becomes a
credential that outlives the page and every check the page is subject to.
The session's agent, if it took such a page, could invite a principal it
controls as an operator of its own session, claim it, and answer its own
escalations from then on. 051 priced a stolen page by its UI session; this
one would be priced by a membership that lasts until the owner notices.

The case against any page: the terminal already holds the owner token, and
an overlay there reaches the same data with none of the browser's attack
surface (a cookie shared across loopback ports, DNS rebinding, script on
the page's origin). The CLI is scriptable. Provisioning is rare. A page
costs a route family, a cookie, a ticket kind and a component to review.

The case for a page: ADR-014 moves multiplayer work into the browser
(`docs/adr/014-second-runtime.md:177-200`). An owner watching sessions
there needs to see who has access and to remove someone quickly, and a
table reads better than JSON lines. Removal is also the case where speed
matters, and removal only reduces authority.

The CLI and the terminal overlay are enough to provision users, and they
come first. If a page is built, it is the fourth option. Neither a page
with the CLI's full powers nor a page whose proposals the terminal
confirms is built.

## Proposal

### Claim tokens

A claim token is `loomclaim_` followed by 64 lowercase hexadecimal
characters: 32 bytes from `token.production_entropy`, the source
invitations and tickets already use. The prefix lets `loom` refuse a claim
given where a bearer belongs and a bearer given where a claim belongs, and
it lets a secret scanner recognize one. The daemon stores the SHA-256
digest of the whole string.

A claim lives 24 hours by default. The request may set `claim_ttl_ms`
between 300,000 (5 minutes) and 604,800,000 (7 days). The daemon stores
the expiry as an instant from `system_time_ms` (`host/bootstrap.gleam:102`),
not from the monotonic clock (`host/bootstrap.gleam:121`), because the
instant must mean the same thing after a restart.

Five rules:

1. A claim names one member principal. The owner has no claims.
2. A claim binds once, to one credential digest. Presenting it again with
   the same digest, while that credential is still active, returns the
   same success. Presenting it with any other digest is `conflict`.
3. A member has either one open claim and no active credential, or no open
   claim. `credentials.rotate` voids the open claim and revokes every
   active credential before it inserts the new claim, or, under enrollment
   by digest (below), the new credential. `credentials.revoke`
   voids the open claim as well.
4. A claim never authenticates anything. Its digest lives in
   `access_claims` and never in `access_credentials`, and `/v2/claim` is
   the only route that redeems a claim. (The owner's listing reads the
   table too, to report a claim's state.)
5. After this change, no reply on the control endpoint carries a bearer.

A claim never travels through a Loom session or page. A claim pasted into
a composer becomes part of the transcript, of any terminal recording, and
of the agent's context, where the agent can redeem it before the invitee
does. The owner delivers it over a channel outside Loom, and the
documentation says so where it describes `claim_command`.

The table, with the catalogue moving from `user_version` 3 to 4 through
the existing forward migration (`storage/catalogue.gleam:141-192`):

```sql
CREATE TABLE access_claims(
  digest TEXT NOT NULL PRIMARY KEY
    CHECK(length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
  principal_id TEXT NOT NULL REFERENCES access_principals(principal_id),
  expires_at_ms INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open', 'claimed', 'void')),
  credential_digest TEXT REFERENCES access_credentials(digest),
  claimed_at_ms INTEGER,
  CHECK((state = 'claimed') = (credential_digest IS NOT NULL)),
  CHECK((state = 'claimed') = (claimed_at_ms IS NOT NULL)),
  CHECK(credential_digest IS NULL OR credential_digest != digest)
);
CREATE UNIQUE INDEX access_one_open_claim
  ON access_claims(principal_id) WHERE state = 'open';
```

Rows are never deleted, as revoked credentials are kept as tombstones
(`storage/access.gleam:10-11`), so a claim cannot be re-bound. An invited
principal has no row in `access_credentials` until the claim, and
`access.authenticate` finds nothing for it (`storage/access.gleam:278-287`).

In `storage/access`, `invite_member` inserts the principal, the membership
and an open claim, and no credential. `rotate_member` and `revoke_member`
void the open claim. A new `claim` function performs rule 2 in one
transaction: it checks the claim's state and expiry, refuses a
credential digest equal to the claim's own digest, checks that the digest
is absent from `access_credentials` and that the principal has no active
credential, inserts the credential, and marks the claim `claimed`, with
the instant as `claimed_at_ms`. The self-digest refusal keeps a careless
or modified client from binding the SHA-256 of the claim string itself,
which would turn the claim string, already sitting in a chat log, into a
durable bearer.

### `sessions.invite` and `credentials.rotate`

Each request gains an optional `claim_ttl_ms`. Each reply replaces `bearer`
with `claim` and `expires_in_ms`:

```
c→s: {v:2, id, cmd:"sessions.invite",
      body:{session_id, principal_id, name, role, epoch, claim_ttl_ms?}}
s→c: {v:2, reply_to, event:"sessions.invite",
      body:{principal_id, name, claim:"loomclaim_<64 hex>", expires_in_ms}}

c→s: {v:2, id, cmd:"credentials.rotate",
      body:{principal_id, epoch, claim_ttl_ms?}}
s→c: {v:2, reply_to, event:"credentials.rotate",
      body:{principal_id, name, claim:"loomclaim_<64 hex>", expires_in_ms}}
```

`expires_in_ms` is a duration, as in `ui.link`, so the client needs no
clock agreement with the daemon. A `claim_ttl_ms` outside its range is
`bad_request`. The other errors are unchanged. The lost-reply rule is
unchanged too (`docs/client-protocol.md` §6.5): a client does not retry
either command, and it recovers a lost invitation by rotating, which now
voids the lost claim instead of revoking a lost bearer.

**Enrollment by digest.** Either request may instead carry
`credential_digest:"<64 lowercase hex>"`, the digest the invitee's `loom
enroll` printed. Then no claim is created: the daemon inserts that digest
as the principal's active credential in the same transaction, under the
same checks as a claim (absent from `access_credentials`, and for
`rotate`, after revoking the active credentials and voiding any open
claim), and the reply is `{principal_id, name}` with no `claim`.
`credential_digest` and `claim_ttl_ms` together are `bad_request`.

`credentials.revoke` keeps its body and reply, and also voids the open
claim.

### `/v2/claim` and `credentials.claim`

`GET /v2/claim` is a WebSocket upgrade carrying
`Authorization: Bearer loomclaim_<64 hex>`. The daemon answers `401` unless
the header has exactly that form and a claim row with that digest exists
and is not `void`. This lookup only filters; the command below decides. The
upgrade takes a control-class parser permit (`root.acquire`, as at
`server.gleam:520`) and its inbound frame limit is 1 KiB.

A spent claim is public from then on: it sits in a chat log, and its row
still exists, so it passes the filter above. Two bounds keep such a token
from holding control permits open. The daemon admits at most one
in-flight `/v2/claim` upgrade per claim digest, the way `root` lets one
process own only one reservation (`root.gleam:410`); a second upgrade for
the same digest is refused with `409` while the first is open. And the
daemon closes the socket if no command arrives within 2 seconds of the
upgrade.

```
s→c: {v:2, event:"hello", body:{protocol:2}}
c→s: {v:2, id:1, cmd:"credentials.claim",
      body:{credential_digest:"<64 lowercase hex>"}}
s→c: {v:2, reply_to:1, event:"credentials.claim",
      body:{principal_id, name, fingerprint:"<16 hex>",
            sessions:[{session_id, role}]}}
```

The daemon performs the claim in one serialized manager dispatch, like
every administration mutation (`manager.gleam:542-564`), then closes the
socket. One connection carries one command.

- `fingerprint` is the first 16 hexadecimal characters of the credential
  digest. It is not secret: it is part of a digest of 256 random bits.
- `sessions` lists at most 16 memberships, in session-ID order, so that
  `loom claim` can print a launch line. The member's own `sessions.list`
  returns the full set (`manager.gleam:1392-1396`).
- Refusals: `not_found` (no such claim, a void one, or a claimed one whose
  credential is no longer active), `expired`, `conflict` (bound to another
  digest, the digest is already a credential, or the digest is the
  claim's own), `bad_request`, `unavailable`. `expired` is a new error
  code.

### `loom claim`

```
loom claim --addr wss://<host>[:port]/v2/control
           [--label NAME] [--state-dir PATH] [TOKEN]
```

1. The token comes from standard input by default: without a `TOKEN`
   argument, `loom claim` prompts for it on a terminal or reads one line
   from a pipe. The argument form is accepted but is not
   what the owner's `claim_command` prints, so the token stays out of the
   invitee's shell history and argument vector by default. Anything but
   `loomclaim_` and 64 hexadecimal characters is refused before any
   connection.
2. `--addr` passes `tui/daemon.valid_address` (`tui/daemon.gleam:421-449`):
   `wss` for any host, `ws` only for a literal loopback address. The claim
   URL is the address with `/v2/control` replaced by `/v2/claim`.
3. The label defaults to the address's host, with the port when it is not
   443. The directory `<state-dir>/remotes/<label>/` is created or checked
   by `bootstrap.ensure_private_directory`, which refuses a link or another
   user's directory and forces mode `0700` (`host/bootstrap.gleam:217-254`).
   `<state-dir>` defaults to `$HOME/.loom`.
4. If the directory already holds `remote.json`, the claim is refused: a
   finished claim lives there. If it holds `credential` and a `claim` file
   naming the SHA-256 digest of this same claim token, that credential is
   reused, which is how a rerun completes an unknown outcome. In every
   other case (no `credential`, or one left by a different claim) `loom`
   draws 32 fresh bytes, hex-encodes them, and writes `credential`, then
   `claim` holding this claim's digest, each with
   `bootstrap.atomic_write_private` (mode `0600`,
   `host_bootstrap_ffi.erl:169-189`), **before** it connects. Tying the
   file to its claim keeps a credential drawn for an earlier, refused or
   rotated claim from being bound to a new one.
5. It connects, sends the digest of the credential, and reads the reply.
   - On success it writes `remote.json` (mode `0600`) holding `addr`,
     `principal_id`, `name` and `fingerprint`, and prints.
   - On `not_found`, `expired` or `conflict` it deletes `credential` and
     `claim`, which authenticate nothing, prints the code, and exits 1. For `conflict` it
     says the claim is bound to another credential and that the owner can
     compare fingerprints and rotate.
   - On an unknown outcome it keeps `credential`, says that rerunning the
     same command completes or refuses the claim, and exits 1.

`loom claim` never prints the bearer. When the argument form was used
anyway, the copy of the token in the shell's history is spent once the
claim is redeemed.

`loom --addr ... --token-file PATH` reads its file through
`read_private_bounded`, as the page launch already does, so a token file
that other users can read is refused. It refuses a file whose content
starts with `loomclaim_`, and `--token VALUE` refuses a value that starts
with `loomclaim_` in the same way.

### `loom enroll`

```
loom enroll --addr wss://<host>[:port]/v2/control [--label NAME] [--state-dir PATH]
```

`loom enroll` is the invitee's half of enrollment by digest. It checks the
address and prepares `<state-dir>/remotes/<label>/` exactly as `loom claim`
does, draws a credential, writes `credential` (mode `0600`) and a
`remote.json` holding `addr`, and prints `{"credential_digest",
"fingerprint", "credential_file"}`. It opens no connection. The invitee
sends the digest to the owner; it is not secret, but the owner confirms
its fingerprint with the invitee over a second channel before inviting
with `--credential-digest`, because a substituted digest would enroll
whoever substituted it.

### What the two sides print

The owner, on the daemon's host (`--claim-addr` is described below):

```
$ loomd access invite 0198c0de-0000-7000-8000-000000000001 alice operator Alice \
    --claim-addr wss://loom.example.com/v2/control
```

Standard error: `principal recovery ID: alice`, as today (`admin.gleam:55`).
Standard output, one line:

```json
{"principal_id":"alice","name":"Alice","claim":"loomclaim_4be1...","expires_in_ms":86400000,"claim_command":"loom claim --addr wss://loom.example.com/v2/control"}
```

`claim_command` does not contain the token. The owner sends Alice both,
over a channel outside Loom, never through a Loom session. Alice runs the
command and pastes the token at its prompt:

```
$ loom claim --addr wss://loom.example.com/v2/control
claim token: 
```

Standard error: `claimed alice at loom.example.com; credential fingerprint
9c1e0f2ab3d4e5f6`. Standard output, one line:

```json
{"principal_id":"alice","name":"Alice","fingerprint":"9c1e0f2ab3d4e5f6","credential_file":"/home/alice/.loom/remotes/loom.example.com/credential","sessions":[{"session_id":"0198c0de-0000-7000-8000-000000000001","role":"operator"}],"launch":"loom --addr wss://loom.example.com/v2/control --token-file /home/alice/.loom/remotes/loom.example.com/credential --session 0198c0de-0000-7000-8000-000000000001"}
```

### Claims, TLS and 052's remote origin

- A claim is presented at the control address's host, on `/v2/claim`. `loom
  claim` refuses `ws` to any host that is not a literal loopback address,
  with the same function the terminal's remote launch uses.
- The daemon cannot see TLS: it binds loopback only and terminates none
  (`docs/client-protocol.md` §2.4). The TLS rule is enforced by the client's
  refusal and by that bind, as it is for bearers.
- Through 052's proxy, `/v2/claim` is one more `/v2` WebSocket upgrade,
  which 052 already requires the proxy to forward
  (`052-web-view-remote-origin.md:148-152`). The token travels in the
  `Authorization` header, not in the query string, so 052's requirement
  to keep `ticket` out of the access log does not need to grow. The
  header already carries every bearer, so this proposal writes down what
  was implicit: the proxy must not log `Authorization`.
- A claim involves no page, no page origin and no cookie. After claiming,
  the member reaches pages with 052's `loom --ui --addr wss://...
  --token-file <credential>` (`052-web-view-remote-origin.md:216-231`).

### `loom access`

`loomd access` and `loom access` become one implementation. The grammar
and the exchange move from `client/daemon/admin.gleam` into a module in
`packages/host`, which both binaries already depend on, and `loomd access`
calls it. Today the CLI checks a request against the daemon's own decoder
before sending it (`admin.gleam:89-92`); `host` cannot import that
decoder, so the client keeps its ID and role checks and leaves the rest to
the daemon, which answers `bad_request`.

```
loom access [--state-dir PATH | --addr URL --token-file PATH] COMMAND
```

Without `--addr`, `loom access` discovers the local daemon exactly as
`loomd access` does. With `--addr`, the address passes `valid_address`
and the owner token file is read through `read_private_bounded`.

| Command | Control command | Standard output | Secret? |
|---|---|---|---|
| `list [--after PRINCIPAL]` | `principals.list` | one JSON line per principal, then `{"next":...}` when there are more | no |
| `show PRINCIPAL [--after SESSION]` | `principals.memberships` | one JSON line per membership | no |
| `invite SESSION PRINCIPAL ROLE NAME [--ttl D] [--claim-addr URL \| --credential-digest HEX]` | `sessions.invite` | `{principal_id, name, claim, expires_in_ms, claim_command}`, or `{principal_id, name}` with `--credential-digest` | **yes**, unless `--credential-digest` |
| `set-role SESSION PRINCIPAL ROLE` | `sessions.set_role` | `{principal_id, name}` | no |
| `revoke SESSION PRINCIPAL` | `sessions.revoke` | `{principal_id, name}` | no |
| `rotate PRINCIPAL [--ttl D] [--claim-addr URL \| --credential-digest HEX]` | `credentials.rotate` | as `invite` | as `invite` |
| `revoke-credentials PRINCIPAL` | `credentials.revoke` | `{principal_id, name}` | no |
| `isolate SESSION --share-existing-transcript` | `sessions.isolate` | `{session_id, domain_scope}` | no |
| `page [--open]` (phase 4) | `ui.admin_link` | the admin page's link | **yes**, a 60-second ticket |

- `set-role` is also how an existing member is added to another session:
  it upserts the membership (`storage/access.gleam:385-420`).
- `--ttl` takes `30m`, `24h` or `7d` forms, within the range above.
- `--claim-addr` sets the address written into `claim_command`, and must
  pass `valid_address`. It defaults to `--addr` in remote mode. In local
  mode it defaults to the discovered loopback address, and standard error
  notes that such a command works only on the daemon's host.
- A secret appears only in `claim` (or in the `page` link), only on
  standard output, and only on success. `claim_command` carries the
  address and not the token. Refusals use the
  fixed codes the daemon already returns and never echo the request
  (`server.gleam:1228-1229`, `admin.gleam:475-487`).

### Listing principals

Both commands are owner-only, refused `forbidden` for a member, and bounded
to 60,000 bytes per page as `sessions.list` is (`server.gleam:1083-1091`).

```
c→s: {v:2, id, cmd:"principals.list", body:{after?:<principal_id>}}
s→c: {v:2, reply_to, event:"principals.list",
      body:{principals:[{principal_id, name, kind:"owner"|"member",
                         credential:{state:"active", fingerprint,
                                     claimed_at_ms?}
                                  | {state:"claim_open", expires_in_ms}
                                  | {state:"claim_expired"}
                                  | {state:"none"}}],
            next?:<principal_id>}}

c→s: {v:2, id, cmd:"principals.memberships",
      body:{principal_id, after?:<session_id>}}
s→c: {v:2, reply_to, event:"principals.memberships",
      body:{principal_id, memberships:[{session_id, name, role}],
            next?:<session_id>}}
```

Rule 3 above is what lets `credential` be one value per principal.
`claimed_at_ms` is present when the active credential was bound by a
claim, and is the wall-clock instant of that claim, so the owner can see
when an invitation was redeemed. `claim_expired` is a member whose only
claim expired unredeemed and who has no active credential; `rotate` issues
a new claim. Neither reply carries a claim or a bearer. The owner has no memberships
(`storage/access.gleam:376-377`), so the owner's list is empty.

### The terminal overlay (phase 3)

A `/access` command in the terminal opens an owner-only overlay, in the
style of `/peers`. It lists principals, their credential state and their
memberships, and it can set a role, revoke a membership and revoke
credentials, each after a y/N review. A member who opens it sees the
`forbidden` from `principals.list` as one line saying the overlay is for
the owner.

The overlay does not invite or rotate. For those it shows the `loom access`
line to run. The one-shot CLI is then the only process that ever receives
a claim, which makes the claim's path short enough to audit. It also keeps
claims out of the terminal's recordings: `--record` writes every key, every
paste and every session-socket message to a file verbatim
(`tui/recording.gleam:91-121`), and a claim shown in or typed into the
terminal would need a redaction rule to stay out of that file.

### The admin page (phase 4)

**Gating.** `loomd --ui --ui-admin`. Without `--ui-admin`, every
`/ui/admin` path is `404` and `ui.admin_link` is `unavailable`. `--ui-admin`
without `--ui` refuses to start.

**Admission.** The owner runs `loom access page [--open]`, which sends:

```
c→s: {v:2, id, cmd:"ui.admin_link", body:{epoch}}
s→c: {v:2, reply_to, event:"ui.admin_link",
      body:{path:"/ui/admin?ticket=<64 hex>", expires_in_ms:60000}}
```

The command is owner-only (`forbidden` for a member) and checks the epoch.
Admin tickets live in their own table, and their grant is a different type
from 051's `ui_sessions.Grant`, so a session ticket never redeems at the
admin exchange and an admin ticket never redeems at a session's.

**Loopback only.** `/ui/admin` is served only when the request's `Host`
resolves to a loopback name (`ui_http.loopback_host`,
`ui_http.gleam:115-130`). Any other `Host` is refused with `403`, the same
answer every `/ui` path gives a non-loopback host today
(`server.gleam:164-165`). When 052 lands, its `Remote(origin)` resolution
keeps that `403` for every `/ui/admin` path. An owner away from the host reaches the page only through
`ssh -L`, which needs a shell account on the host.

| Method and path | Purpose |
|---|---|
| `GET /ui/admin?ticket=<t>` | Exchange: `Sec-Fetch-Site` is `none` or `same-origin`; sets the cookie; the body carries the page nonce; the enter script moves to the keyed page. |
| `GET /ui/admin/p/<key>` | The page shell: `Sec-Fetch-Site` as above, the cookie, and the key. |
| `GET /ui/admin/p/<key>/ws?csrf-token=<nonce>` | The socket: `Origin` exactly `http://` and the `Host`, the cookie, the key, and the nonce, compared in constant time. |

The cookie is `loom_admin=<value>; HttpOnly; SameSite=Strict;
Path=/ui/admin/p/<key>`. The key, the nonce and the response headers work
as in 051's operator addendum (`051-web-view-route.md:570-632`). An admin UI
session lives 15 minutes from the exchange, not 8 hours, and a new exchange
ends the previous one. Every frame re-checks that the minting credential
still authenticates as the owner, through the same `authorize_admin` that
every administration dispatch runs (`manager.gleam:1594-1611`).

**What the page shows.** The data of `principals.list` and
`principals.memberships`, with session names for the membership rows. All
of it is drawn as text nodes; no attribute or handler value comes from
data. The page draws no transcript and no session content.

**What the page does.** The component's message type has exactly
two commands: `RevokeMembership(principal, session)` and
`RevokeCredentials(principal)`. They map to the manager's
`RevokeMembership` and `RevokeMember` administration constructors
(`manager.gleam:489-510`). Each is a two-step button ("Revoke", then
"Confirm revoke alice"), `type="button"`, with no keyboard handler. The
two-step button guards against a mis-click; it is not a security boundary,
because both commands only reduce authority. The type has no constructor
for invite, set-role or rotate, since those grant authority or produce a
secret.

**Grants from the page.** The page has no path to a grant. For an
invitation, a role change or a rotation it renders, as text, the `loom
access` line that performs it, built from the form the owner filled in,
with every argument single-quoted for the shell. The owner copies the line
into a terminal, reads it, and runs it; the claim, when there is one,
reaches only that terminal's standard output. The terminal overlay does
the same (phase 3). A line rendered by a page the agent had taken is text
the agent chose, like any text 051's addendum assumes the agent can put in
front of the person, and the owner is running a command that names what
it grants.

### The admin page's threat model

051's operator addendum is the baseline: the session's agent can reach the
loopback listener unless the session runs with `--network off`, it can put
text in front of the person, browsers send a cookie to every port of a
host, and a page stands on a cookie, a key and a nonce
(`051-web-view-route.md:445-632`). This proposal assumes, as 051 does, that
the session's read scope does not cover the daemon's state directory. If
it does, the agent can read `owner.token` directly, and no page design
changes the outcome (`051-web-view-route.md:791-792` makes the same
observation for `--open`).

The admin page goes further than 051 in eight ways:

1. It needs its own flag, `--ui-admin`.
2. It is served on loopback only, never on a remote origin.
3. Its link is minted only for the owner, over the owner token.
4. Its UI session lasts 15 minutes.
5. Its component can only reduce authority, and the reduction is fixed by
   the message type.
6. It has no path to a grant. It renders the `loom access` line, and the
   owner runs it in a terminal.
7. It draws no session content, so no text the agent wrote reaches it.
8. Its ticket table, grant type, cookie name and cookie path are its own.

If the agent obtained all three secrets anyway, it could remove members,
revoke credentials, and read principal IDs, names and memberships. It could
not grant a membership or obtain a credential. That worst case is a denial
of service, which is why the page does not also require `--network off`;
051 rejected that coupling for operator pages
(`051-web-view-route.md:698-699`), and the reasons hold here.

### Where a claim token exists

A claim is created in the daemon's control handler and carried in one reply
frame to the `access` CLI, over loopback or TLS. The CLI writes it to
standard output. From there it is wherever the owner sends it, then in the
invitee's standard input (or argument vector, if the invitee chose that
form), then in one `Authorization`
header over TLS, where the daemon hashes it. It never passes through a Loom
session or page (see "Claim tokens").

It is never in the catalogue (only its digest), a daemon log line, a URL, a
page, Loom's terminal UI, or a recording. One exposure is shared with today's
bearer: if the handler process crashed while holding the reply, an OTP crash
report could write it to `daemon.log`. A claim found there afterwards is
spent or expires within its lifetime; a bearer found there works until
rotation.

## Frozen-interface impact

Only Part 1.6 changes. Parts 1.1 to 1.5 do not. The catalogue schema is not
a Part 1 interface: Part 1.2 describes conversation storage
(`docs/loom-implementation-spec.md:150-170`).

| Phase | Change in Part 1.6 |
|---|---|
| 1 | New route `/v2/claim`, authenticated by a claim token, carrying the one command `credentials.claim`. |
| 1 | `sessions.invite`: optional `claim_ttl_ms`; reply drops `bearer`, adds `claim` and `expires_in_ms`. |
| 1 | `credentials.rotate`: as `sessions.invite`. |
| 1 | `credentials.revoke`: also voids an open claim; wire shape unchanged. |
| 1 | `sessions.invite` and `credentials.rotate`: optional `credential_digest` for enrollment by digest; with it the reply carries no `claim`. |
| 1 | New error code `expired`. |
| 2 | New owner-only `principals.list` and `principals.memberships`. |
| 4 | New routes `/ui/admin`, `/ui/admin/p/<key>`, `/ui/admin/p/<key>/ws`; new owner-only `ui.admin_link`. |

This supersedes one sentence of 015's addendum: "Only a successful
invitation or rotation reply contains the fresh bearer"
(`015-daemon-control-and-session-attachments.md:334`). After phase 1, no
reply contains a bearer. `docs/client-protocol.md` §2.3, §3.11, §3.13 and
§6.5 change to match, and the spec's list of control commands, which
already omits the six administration commands
(`docs/client-protocol.md:3106-3112`), gains them along with these.

## Phasing

Each phase ships on its own and leaves the tree consistent. The owner
accepted this proposal on 2026-09-27 and asked for phase 1 to be built
first; phases 2 to 4 wait for their own go-ahead.

1. **Claims.** The `access_claims` table and the version 4 migration; the
   new `sessions.invite`, `credentials.rotate` and `credentials.revoke`;
   `/v2/claim` and `credentials.claim`; `loomd access` printing claims and
   `claim_command`; `loom claim` and `loom enroll`; enrollment by digest;
   the `--token-file` read through `read_private_bounded`. Useful alone: from this phase on, no invitation
   or rotation hands a live credential to a chat channel. Phase 1 is the
   first step.
2. **`loom access` and listing.** The shared grammar module in `host`;
   `loom access` locally and over `wss`; `principals.list` and
   `principals.memberships`. Useful alone: the owner can see who has
   access, and can administer from the client shipment.
3. **The terminal overlay.** `/access`, owner-only: list, set-role, revoke,
   revoke credentials. Useful alone for an owner who works in the terminal.
4. **The admin page.** `--ui-admin`, `ui.admin_link`, the `/ui/admin`
   routes, and the read-and-revoke component, which renders grants as
   `loom access` lines. Build it only if phase 3 leaves a need for the
   browser view.

## Verification required

Phase 1:

- A claim binds once. A `credential_digest` equal to the claim's own
  digest is refused with `conflict`.
- A second concurrent `/v2/claim` upgrade for the same claim digest is
  refused while the first is open, and an upgrade with no command is
  closed after 2 seconds.
- `principals.list` reports `claimed_at_ms` after a claim and
  `claim_expired` for an unredeemed expired claim.
- An invitation with `credential_digest` creates the credential and no
  claim, and its reply carries no `claim`. A second presentation with another digest is
  `conflict`; with the same digest, while the credential is active, it
  returns the same body; after that credential is revoked it is
  `not_found`.
- An expired claim is `expired`. A claim voided by `rotate` or `revoke` is
  `not_found`.
- Two concurrent claims of one token with different digests: exactly one
  succeeds.
- A claim token presented as a bearer on `/v2/control` gets `401`, and a
  bearer presented on `/v2/claim` gets `401`.
- The `sessions.invite` and `credentials.rotate` replies carry no `bearer`,
  and an invited principal has no row in `access_credentials` until it
  claims.
- An open claim still redeems after a daemon restart.
- A version 3 catalogue migrates to version 4 with its principals intact.
- `loom claim` writes `credential` at mode `0600`, in a `0700` directory,
  before it connects, with `claim` naming this claim's digest. With the
  reply dropped, a rerun completes. A `credential` left by a different
  claim is replaced, not reused. A refusal deletes both files. It refuses
  `ws://` to a non-loopback host, and it refuses a bearer-shaped token.
  Without a `TOKEN` argument it reads the token from standard input, and
  the owner's `claim_command` contains no token.
- `loom --addr ... --token-file` refuses a group-readable file, and both
  `--token-file` and `--token` refuse a claim-shaped value.
- Mutations, each applied alone and reverted, each fail a named test:
  - the single-binding check is removed;
  - `authenticate` also consults `access_claims`;
  - the expiry check is removed;
  - the self-digest refusal is removed;
  - the one-upgrade-per-digest bound is removed;
  - `rotate` leaves the previous claim open;
  - `loom claim` writes `credential` after the exchange instead of before.
- A drive through a real TLS proxy set up as 052 describes: invite, claim
  over `wss`, then attach and open a page with the claimed credential.

Phase 2:

- A member's `principals.list` and `principals.memberships` are
  `forbidden`.
- Pages stay within 60,000 bytes and resume with `after`.
- No listing reply contains `loomclaim_` or a 64-character credential.
- `loomd access X` and `loom access X` print the same bytes for the same
  command against the same daemon.

Phase 4:

- Every `/ui/admin` path is `404` without `--ui-admin`. With it, a
  request whose `Host` `ui_http.loopback_host` refuses is answered `403`;
  the test drives `loopback_host` directly with a non-loopback name, since
  052's `Remote(origin)` is not implemented yet.
- A member's `ui.admin_link` is `forbidden`. A session ticket at the admin
  exchange and an admin ticket at a session exchange are refused.
- The admin UI session ends at 15 minutes, and a second exchange ends the
  first.
- No frame on the admin page's socket contains `loomclaim_`; a grant
  appears only as a rendered `loom access` line.
- Mutations, each failing a named test: `/ui/admin` served for a
  non-loopback `Host`; an `Invite` constructor added to the component's
  message type; 051's `loom_ui` cookie accepted at an admin route.

## Cost

- **Breaking change to two replies.** Scripts that read `bearer` from
  `loomd access invite` or `rotate` break, and the invitee now runs
  `loom claim`. `loomd access` and the daemon ship in one binary, so there
  is no version skew between them.
- **The invitee needs a `loom` with `claim`.** An older client cannot
  redeem a claim.
- **The catalogue moves to version 4.** An older daemon refuses a version 4
  catalogue (`storage/catalogue.gleam:190`), so a downgrade after phase 1
  needs the catalogue restored from before the upgrade.
- **Wall-clock expiry.** A clock moved backward lengthens an open claim,
  and one moved forward shortens it.
- **A third `/v2` route**, authenticated by a claim rather than a
  credential, with its own permit use.
- **Remote administration** with `loom access --addr` works only with the
  owner token on a second machine.
- **The claim still crosses the owner's channel**, and sits in standard
  output and the chat until it is redeemed, and in the invitee's shell
  history if the invitee passes it as an argument.
  Its exposure is bounded by single use and its lifetime, not removed.
- **Wrong-person redemption is caught only by checking.** The rightful
  invitee's `conflict`, `claimed_at_ms` and the fingerprint comparison
  reveal it, but only if someone looks; the owner confirms fingerprints
  out of band, and uses enrollment by digest for operator roles.
- **The admin page, if built**, adds a route family, a cookie, a ticket
  kind and a component to review, and one more flag an owner must
  understand.

## Decision

**Proposed.** An invitation carries a single-use claim token that expires
in a day by default. The invitee's `loom claim` draws its own credential,
stores it at mode `0600`, and binds it to the claim by digest over `wss` on
a new `/v2/claim` route, so no bearer crosses a chat channel, a lost claim
reply is recovered by rerunning the same command, and a claim redeemed by
the wrong person can be detected from the rightful invitee's `conflict`,
the listing's `claimed_at_ms`, and a fingerprint the owner confirms with
the invitee out of band. For operator roles the owner can instead enroll
the invitee by digest, so nothing secret crosses the channel. A claim never
travels through a Loom session or page. No
control reply carries a bearer after this change. `loomd access` and a new
`loom access` share one implementation and add listing; the terminal gains
an owner overlay that reads and reduces access. An admin web page, if it is
built, is loopback-only, reduces authority only, and renders every grant
as a `loom access` line for the owner to run in a terminal.

A bearer in the invitation was rejected because its interception is
silent. A daemon-minted credential in the claim reply was rejected because
a lost reply loses the credential. Enrollment by digest is offered
rather than required, because it needs two messages. A page with the
CLI's full powers was rejected because a stolen one would give the
session's agent a durable membership, not an 8-hour page. A page whose
proposals the terminal confirms was rejected because an agent holding the
page could lodge a proposal and then ask the owner to confirm it.

## Step 1 as built

Step 1 follows the proposal above. Where the code had to choose, or could
not check an item yet, it did this:

- **The one-upgrade bound lives in the root's allocation map.** A claim
  socket reserves a `Claim(digest)` connection class, and the root refuses a
  second allocation of the same class. That allocation already lasts from
  the HTTP request to the socket process's exit, so no second table or
  monitor was needed.
- **Digest comparisons are injected into `storage/access.claim`.** The daemon
  passes `broker/internal/ffi_crypto.constant_time_equal`; storage has no
  crypto dependency of its own.
- **An upgrade refused with 401 or 409 is an unknown outcome to `loom
  claim`.** The client cannot tell those statuses from an unreachable daemon
  through the shared transport, so it keeps `credential` and `claim` and
  says to rerun. Only the command's `not_found`, `expired` and `conflict`
  delete them, as the proposal says; `bad_request` and `unavailable` keep
  them.
- **`loom claim` forces `<state-dir>` to `0700` as well as `remotes/` and
  `remotes/<label>/`,** because `<state-dir>` defaults to the local daemon's
  own state directory, which is held to the same rule.
- **Two verification items wait for later steps.** `principals.list`
  reporting `claimed_at_ms` and `claim_expired` needs the listing, which is
  step 2; step 1 records `claimed_at_ms` and a test reads it from the row. The
  drive through a real TLS proxy was not run; the end-to-end drive used the
  daemon's loopback listener with `ws://`.

## Open

- **Removing `loom --token BEARER`**, which puts a bearer in the argument
  vector.
- **`principals.rename`.** `storage/access` already has `rename`
  (`storage/access.gleam:312`); no control command exposes it.
- **A `--remote LABEL` launch** that reads `remotes/<label>/` instead of
  taking `--addr` and `--token-file`.
- **Rotating the owner token**, which has its own lifetime and no command.
