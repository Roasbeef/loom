# Signing a phone into the web view without a shell on the daemon's box

Status: **PROPOSED**. Written against `main` at `ffdfdeeb9` on 2026-11-20.
Nothing here is built. A citation names a file and line in that tree; a
sentence marked *(inference)* is my reading of code or of Tailscale
behaviour that I did not run, and the owner should treat it as a question.

## 1. The problem

The distributed daemon runs on a Linux box on the owner's tailnet and is
served over Tailscale Serve at an `https://<node>.<tailnet>.ts.net` origin
listed in `[daemon] ui_origins` (`docs/configuration.md:461`,
`docs/architecture/web-view.md:1888-1940`). A browser on the phone can
reach that origin. It cannot get in, because every way into the web view
starts from a credential the daemon has already issued:

1. **`loom ui` on the box.** `ui.link` mints a `Remembered` `Home` ticket,
   `Fresh`, for the credential on the control connection
   (`packages/client/src/client/daemon/server.gleam:4651-4670`). The ticket
   is single-use and lives 60 seconds. `loom ui --device` mints the same
   ticket for ten minutes and draws a QR code (`server.gleam:4676-4700`;
   `docs/architecture/web-view.md:1936-1940`). Both need a process on the
   box that holds a control credential, so from a phone the owner has to
   open a shell on the box first.
2. **A fresh home's "Sign in another device".** `ui_socket.device_link_for`
   mints a ten-minute `Remembered` ticket for the page's principal
   (`packages/client/src/client/daemon/ui_socket.gleam:3222-3290`). It is
   refused from a home that was reached from the bookmark: the check at
   `ui_socket.gleam:3231-3236` returns `NotFresh` when the page's origin is
   `Resumed`. The home draws no control for it in that case
   (`docs/architecture/web-view.md:1708-1713`).
3. **The bookmark.** `POST /ui/l/<key>/home` (`server.login_resume`,
   `server.gleam:1545`) opens a `Resumed` home from a thirty-day login
   cookie plus a nonce held in that browser's `localStorage`
   (`web-view.md:1664-1700`). It cannot help a browser that has no login yet.
4. **The browser claim.** `POST /ui/claim` (`server.claim_submit`,
   `server.gleam:1649`) turns an invitation token into a login. It is for a
   new person, not for the owner, and the owner would need a `loomclaim_`
   token, which `loom` on the box also issues (`web-view.md:1740-1770`).

So the first browser ever signed in must come from `loom ui` on the box. A
later browser must come either from a shell on the box again or from a
*fresh* home, which is a home the person opened with `loom ui` within the
last eight hours. A laptop whose login was resumed from its bookmark
cannot sign the phone in. A login also ends thirty days after it was
issued, with a fixed expiry (`ui_login.gleam:160-168`, `:288`;
`065-web-workspace-mode.md:753-757`), so every browser needs `loom ui` on
the box again at least monthly. In practice the owner is at a shell on the
box whenever the phone needs access.

What the owner asked for: reach the daemon from the phone the way Tailscale
login works, with the approval given by something already in the owner's
hand, such as a passkey on the laptop, and no login command on the box.

### Constraints that shape every option

- **The agent threat model.** Protocol-change/051 and `web-view.md:2014-2025`
  treat the session's own agent as the main attacker of the loopback
  listener: its tools can reach `127.0.0.1:<bind port>` unless the session
  runs with `--network off`. Any scheme that trusts something a loopback
  client can write is open to it. This is why the daemon never reads
  `X-Forwarded-*` (`web-view.md:1942-1950`).
- **Where a sign-in ends.** Every route into a browser ends in
  `ui_login.issue`, which writes one catalogue row of kind `browser` and
  signs a macaroon-style token from the root key
  (`packages/client/src/client/daemon/ui_login.gleam:152-170`). A new way to
  sign in is a new way to reach that function, with a principal, a ceiling
  and a `Fresh` or `Resumed` origin. The ticket and the login cookie after
  that are unchanged.
- **Fresh versus resumed.** `Fresh` is the only origin that may mint an
  `Admin` ticket or a device link (`protocol-change/065-web-workspace-mode.md:191-193`).
  Each option has to say which origin it produces.
- **Custom FFI is a last resort**, confined to `internal/ffi_*.gleam`, with
  a comment naming the OTP function and why nothing else can do it
  (`docs/gleam-style.md:1522-1532`).

## 2. Options

### 2a. Tailnet identity

**Mechanism.** The owner configures the tailnet login that is the owner,
for example `[ui] tailnet_owner = "user@github"` (a new key; no tailscale
key exists today, `docs/configuration.md` has only `ui_origins` at line
461). A request that arrives through Serve is attributed to the tailnet
user that Tailscale authenticated. If that user is the configured one, the
daemon mints a login for the owner principal with no ticket. A phone on the
tailnet signed in to the owner's Tailscale account then opens the origin and
lands on its home with nothing else.

**What Serve forwards.** For a request from a tailnet device, Serve adds
`Tailscale-User-Login`, `Tailscale-User-Name` and
`Tailscale-User-Profile-Pic` headers to what it sends to the backend. It
does not add them for Funnel traffic. *(inference from Tailscale's Serve
documentation; I did not run Serve here.)* Serve proxies from the local
machine, so the TCP peer address the daemon sees is loopback, not the
phone's tailnet address. *(inference.)* `tailscale whois <ip:port>` and the
LocalAPI `GET /localapi/v0/whois?addr=` need the *remote* address of the
connection, which the daemon therefore does not have for a Serve-proxied
request. The two ways to identify the peer are the headers, and a lookup
using a source address that Serve would have to pass along. I know of no
header Serve sets for the second. *(inference.)*

**How the daemon would tell a real Serve request from a forged one.** It
cannot, from the request alone. Serve strips identity headers that a
tailnet client tries to send and sets them itself, and it sets none for
Funnel traffic or for tagged devices (Tailscale kb/1312). That protects
against a forged header arriving *through* Serve. It does not protect
the loopback listener behind Serve: any local process on the box can
connect to it with a listed `Host` and write the header itself. The
options are:

1. *Trust the loopback listener.* Accept the headers, since Serve is the
   only thing that is supposed to connect. Whether that fails the 051
   model depends on the session's `network` setting. Under `network =
   "full"`, which is the default (`bwrap.go:67-70`, `:225-236`;
   `docs/architecture/effects.md:316-320`), a session's tools can run
   `curl -H 'Tailscale-User-Login: user@github'
   http://127.0.0.1:4100/...` with the listed `Host` and obtain the
   owner's login, which is owner authority. Under `off`, `loopback` or
   `proxy` that path is closed *(inference: I read the sandbox
   settings, not their enforcement for loopback connects)*. So the
   forgery premise holds for the default only.
   - *The cheap variant.* Trust the header only when the daemon's
     network setting is `off`, and mint the login as `Resumed`. It is
     safe against the session's agent by the argument above, and a
     `Resumed` login cannot mint device links or open the admin page.
     It rarely helps: it needs every session on the box to run with no
     network, which a coding agent that fetches dependencies and talks
     to a model provider cannot do, and any other local process on the
     box can still forge the header.
2. *Serve to a unix socket.* Serve can forward to `unix:/path`. *(inference.)*
   Filesystem permissions on the socket would then replace the loopback
   port as the gate. The daemon cannot listen there today:
   `glisten.bind` accepts an address, not a socket path
   (`glisten.gleam:325-337`), so this means forking glisten and mist.
   That is a large cost for one option.
3. *Bind the tailnet address and verify with `whois`.* The daemon listens
   on the node's `100.x` address, reads the real peer address, and asks
   `tailscaled`. That is robust. It has no TLS, so the page is not a secure
   context: `__Secure-` cookies and `Secure` are unusable, WebAuthn is
   unavailable, and the origin model of protocol-change/052 does not
   apply. It is a different product from the one built.

**What it trusts.** `tailscaled` on the box, the tailnet's own login and
device authorization, and, in option 1, the absence of any hostile local
process, including a session's agent under `network = "full"`.

**Code it needs.** A config key and its validation; a source of the
tailnet identity (a header read, or a call to `tailscale whois --json`
through a spawned process, or the LocalAPI over its unix socket, which needs
a client for HTTP over a unix socket that `gleam_httpc` is not *(inference)*);
a route or an extra branch in `server.web_view` (`server.gleam:568`) that
calls `ui_login.issue` for the owner; and tests.

**Cost.** Smallest UX of any option, and the only one needing nothing from
the owner's laptop. The cost is the trust in the headers. Under the
default `network = "full"`, a session's agent can obtain the owner's
thirty-day login. I would not build 2a on the loopback listener.

### 2b. Passkeys (WebAuthn)

**Mechanism.** From a fresh home the owner presses "Add a passkey". The page
calls `navigator.credentials.create` with the rpId set to the origin's host
(for example `obelisk.tail0a99b.ts.net`). The browser makes a key pair on
the device (or in iCloud Keychain / Google Password Manager, which sync it
to the phone), and the page posts the attestation to the daemon, which
stores the credential id and public key against the owner principal. Later,
any browser on that origin opens the sign-in page, calls
`navigator.credentials.get`, and posts the assertion. A phone with the
synced passkey signs in with Face ID. A phone without it uses WebAuthn's
cross-device flow: the browser shows a QR code, the laptop (or phone) with
the passkey approves over Bluetooth proximity, and the assertion arrives
as usual. No shell, no ticket.

**Registration needs a `Fresh` home** (the owner has just proved a control
credential), and the credential row belongs to the page's principal.

**What the daemon verifies at sign-in.** In order, for an assertion from the
sign-in page:
1. The challenge is one the daemon issued, for this request, unexpired and
   unused (single use, held in the same actor as tickets).
2. `clientDataJSON` has `type` `webauthn.get`, that challenge, and an
   `origin` equal to a listed origin byte for byte. The origin check is what
   keeps another service on the same host and a different Serve port from
   using a signature meant for this one: the browser scopes a passkey by
   rpId (the host), not by port, and so would let that service ask, but the
   signed `origin` would not match.
3. `authenticatorData` has an rpIdHash equal to SHA-256 of the configured
   host, the user-present and user-verified flags set (require UV), and a
   signature counter greater than the stored one when either is nonzero.
   Synced passkeys commonly report a counter of zero; the rule must accept
   that and not treat it as a clone *(inference from WebAuthn level 2)*.
4. The signature, ES256 (ECDSA over P-256 with SHA-256), verifies over
   `authenticatorData ++ SHA-256(clientDataJSON)` under the stored public
   key.
5. The credential id is on file and its row is active. The principal is
   the row's principal.

At registration the daemon additionally parses the attested credential
data. It accepts attestation `none` only: there is no vendor trust to
establish for a single-owner daemon.

**What provides the cryptography.** `kryptos` 1.5.0 is already locked
for `client` (`packages/client/manifest.toml:55`), pulled in through
`gose`. It provides `kryptos/ec.public_key_from_der(der) ->
Result(PublicKey, Nil)`, which takes SPKI DER of a named curve;
`kryptos/ec.public_key_curve(key)`, to check the curve is `P256`; and
`kryptos/ecdsa.verify(public_key, message, signature, hash)`, which takes
a DER signature and a hash algorithm and returns `Bool`. I read these in
the kryptos 1.5.0 source in another package's build directory
(`packages/conformance/build/packages/kryptos/src/kryptos/`), since
`packages/client` has no build directory in this worktree. So the plan is
to add `kryptos` as a direct dependency of `client` (and hand-update any
downstream `manifest.toml` requirements line, as the path-dependency
hazard notes), hash with `gleam_crypto`, and write **no `@external`** and
no `.erl` file. That meets the style rule that custom FFI is a last
resort (`docs/gleam-style.md:1522-1532`).

The browser removes the need for a CBOR or COSE decoder. Its
`AuthenticatorAttestationResponse.getPublicKey()` returns the credential
public key as SubjectPublicKeyInfo DER, and `getAuthenticatorData()`
returns the authenticator data bytes, so the page sends both and the
daemon passes the key to `public_key_from_der`, requires curve `P256`, and
stores the DER. Browsers new enough for passkeys ship both methods
*(inference)*. At sign-in the daemon verifies the signature over
`authenticatorData ++ sha256(clientDataJSON)`. I would refuse everything
but ES256 and say so on the registration page; supporting another
algorithm would need a COSE reader.

**What it trusts.** The browser's WebAuthn implementation and the platform
authenticator; the rpId and origin check; the Serve certificate (the
origin must be a secure context, which a `*.ts.net` HTTPS name is). It does
not trust the network, any header, or the box's local processes: the
signature cannot be forged from the loopback listener without the private
key.

**What it produces.** A `Browser` login for the passkey's principal, minted
through `ui_login.issue`. I propose the sign-in count as `Fresh`: a
user-verified assertion is stronger evidence than a `loom ui` ticket, and
without it a phone signed in with the passkey could never itself mint a
device link or open the admin page. That is a ruling for the owner (see
section 4), because 065 ruled that only a `loom ui` exchange is fresh.

**Page and policy implications.** The sign-in page needs script that calls
WebAuthn and then posts. Today the resume page is the only `/ui` document
that posts a stored nonce, and it works under `form-action 'self'` with
`script-src 'self'` (`packages/web_view/src/web_view/page.gleam:1083-1130`;
`web-view.md:1690-1698`). The enter page and most documents carry
`connect-src 'self' <socket>`, so `fetch` to the origin is allowed there,
but the resume policy is the form-based one. A passkey page needs
`connect-src 'self'` (for challenge fetch and assertion post) or a
two-form flow. It does not need `unsafe-inline`: the script is a served
asset, as `web_view_resume.js` is. The mermaid child policy at
`page.gleam:100` uses `sandbox allow-scripts` without `allow-same-origin`,
which would give WebAuthn an opaque origin and make it fail; the passkey
page must not copy that policy. *(inference: I did not run it.)*
`Permissions-Policy` does not need to be widened for same-origin use, since
`publickey-credentials-get` defaults to the document's own origin.

**Code it needs.** A catalogue table of credentials (credential id, public
key, principal, counter, created, last used, label) and a schema migration
with its generated SQL (`make gen-sql`; `packages/storage/src/storage/`
carries one `catalogue_*_schema.gleam` per table); registry calls to add,
list, authenticate and delete; a challenge table in `ui_sessions` or its
own actor; three routes (`GET /ui/signin`, `POST` for options and for the
assertion) with `Sec-Fetch-Site: same-origin` rules as the resume has
(`ui_http.same_origin_post`, `ui_http.gleam:581`); two pure modules in
`web_view/host` for the byte parsing and checks (property-tested on both
targets, like `host/login`); the kryptos dependency and no FFI; one asset
script and
its policy; a "Passkeys" list with delete in the account panel beside
"Sign-ins" (`web-view.md:1700-1708`); the root page's text for a browser
with no login (`web-view.md:1964-1990`) pointing at the sign-in page.

**Cost.** The largest build here: a migration, a new credential class
beside `bearer` and `browser` (065 added the kind column so this is
anticipated; the kind column is described in the same review addendum,
`065-web-workspace-mode.md:880-921`), a new direct dependency, and
real browser testing on iOS and desktop. The failure modes are a lost
passkey with no recovery other than `loom ui` on the box (which stays), and
a synced passkey that is only as safe as the owner's cloud account.

### 2c. Let a resumed home mint a device link

**Mechanism.** Delete the `Resumed` refusal in `device_link_for` and the
control's omission, so a home reached from the bookmark draws "Sign in
another device". The owner presses it on the laptop's resumed home, scans
the QR code with the phone, and presses the confirmation button
(`web-view.md:216-244`).

**Why it was refused.** Protocol-change/065 states the rule in two places
(`:191-193`, `:389`, `:467`) and gives the reason in its review addendum
(`:880-921`): a device link from any home turned a stolen eight-hour page
into a thirty-day credential, and an admin page re-mintable from a resumed
home made the fifteen minutes a page lifetime rather than a credential
bound. The Cost section says a stolen *fresh* home is worth a login
(`:758`), and that a stolen login does everything a resumed home can for
thirty days "but no admin page and no device link, which only a fresh home
mints" (`:753-757`). The owner ruled the `Fresh | Resumed` origin on
2026-10-04 (`:910`, `:921`).

**What has changed since.** The review also fixed the part of the risk
that was about lifetime. A device-link login inherits the issuing login's
expiry and names it as parent (`ui_socket.gleam:3200-3210` doc, passing
`standing.login` at `:3274-3280`; `065:921`), and the grant allowance
(three an hour) applies (`:757-759`). So a stolen bookmark cannot extend
its own thirty days by minting children.

What remains is that revoking a login does **not** cascade.
`access.gleam:1477-1497` revokes only the one row, and the `EndLogin` case
in `ui_sessions` (`:1296-1306`) ends only that login's own pages. A thief
who mints a child before the owner revokes the parent keeps the child. So
2c needs a transitive `issued_by` cascade, in the registry and in the page
tables, built first.

Two more constraints. The new device link must keep `origin:
standing.origin`; `device_link_for` mints `Fresh` today (`ui_socket.gleam:3268`),
which is correct only because a `Resumed` page cannot reach it. If the
`Resumed` arm is removed and that line is left alone, a stolen bookmark
yields a `Fresh` home with admin access. And the phone's login expires with
its parent, so at most thirty days after the laptop's login both need
`loom ui` on the box again.

**What it trusts.** That the person holding a resumed home is the owner. It
adds no new factor; it moves trust from "was at a shell within eight
hours" to "has a laptop whose bookmark is valid".

**Code it needs.** Remove the `Resumed` arm in `device_link_for`
(`ui_socket.gleam:3231-3236`) and pass `origin: standing.origin` instead of
`Fresh` at `:3268`, so the minted ticket stays `Resumed`; let the home draw
the control (`view/signins`); update the tests that assert a resumed home
is refused; add the revocation cascade above; and amend 065 with an
addendum for the new ruling. No storage change beyond the cascade query.

**Cost.** Medium once the cascade is counted. It solves the phone only when
some browser of the owner already has a login, and it lasts at most thirty
days from that login, after which `loom ui` on the box is needed again. It
also weakens the 2026-10-04 ruling, which is the owner's to change.

### 2d. Approval from a signed-in browser (a pairing code)

**Mechanism.** The same trust as 2c, with the exchange running the other
direction, as in the OAuth device authorization grant (RFC 8628). The phone
opens `/ui/pair` on the listed origin and is shown a short code and starts
polling with a secret handle held only by that page. A signed-in browser's
home lists "A device is asking to sign in: code `K7P-4QD`" with Approve and
Deny. On Approve the daemon mints the login for the phone's poll. The
owner compares the code on the two screens, which prevents approving a
request an attacker started.

**What it adds over 2c.** No QR code to scan or link to move, no
`Sec-Fetch-Site` confirmation step (the phone started the request itself),
and the person decides after seeing which device asks. It adds an
unauthenticated endpoint that creates pending state, so it needs a hard
cap on pending requests, a short expiry, and a rate limit like the claim's
reservation (`root.acquire_claim`, `web-view.md:1750-1754`).

**What it trusts and the residual risk.** The approving browser and the
person comparing codes. An attacker who starts a request and persuades the
owner to approve it gets a login; the code defeats a request the owner did
not see, not one the owner was talked into. The approver must be allowed to
mint a login, so the same fresh-or-resumed ruling as 2c applies.

**Code it needs.** A pending-requests table in `ui_sessions` (memory only,
as tickets are), two routes, a home panel row and a socket event, and a
page. No storage migration and no FFI.

**Cost.** Medium. It is better than 2c in flow but is more code for the same
authority.

### 2e. Other ideas I considered

- **Tailscale SSH or a `loom` CLI on the phone.** A terminal app that runs
  `loom ui --device` over Tailscale SSH works today and needs no change.
  It is the shell the owner is trying to avoid.
- **A long-lived bearer token in the phone's password manager**, pasted into
  a sign-in form. It is a credential that never expires the way a login
  does and that a form posts in the clear to the daemon; it is worse than a
  passkey and adds a second path to `ui_login`. Rejected.
- **A "remember me" for the device link that lasts one use but not ten
  minutes**, e.g. a link the owner emails or messages to themselves.
  The link is a bearer ticket in a third-party store. Rejected.
- **Tailscale Serve with `--set-path` or Funnel auth.** Funnel exposes the
  origin to the internet and removes the headers. Rejected.

## 3. Recommendation

1. **Build 2b, passkeys, now.** It matches the request ("use my passkey"),
   needs no shell and no already-signed-in browser, and defends against the
   agent threat model, since a signature cannot be forged from the
   loopback listener. It uses `kryptos` and `gleam_crypto` and needs no
   FFI. It needs a **new protocol-change at the next free number** (127 if
   branch 126 lands first; check `ls protocol-change` at filing): the
   credential table and catalogue migration, the three routes, the
   challenge lifetime, the `Fresh` ruling for a passkey sign-in, and the
   kryptos dependency. Staged as: pure verification with property tests;
   the table and registration from a fresh home; the sign-in page and the
   account panel list.
2. **2c only as a stopgap**, if the owner reverses the 2026-10-04 ruling,
   and only with the two fixes above: the transitive `issued_by`
   revocation cascade, and `origin: standing.origin` on the minted ticket.
   It needs an **addendum to `protocol-change/065`**, not a new number.
3. **2a stays rejected** under `network = "full"`. The `off`-only,
   `Resumed` variant is safe against the agent but rarely applicable. A
   unix-socket Serve target would mean forking glisten and mist.
4. **2d only if** the owner wants the phone to initiate. It is 2c with more
   code and the same trust, and needs the same cascade.

Whatever is built, `loom ui` on the box stays as the recovery path for a
lost passkey and as the way to sign in the first browser. Whether a
passkey sign-in counts as `Fresh`, with user verification required, is the
owner's ruling (section 4, question 3).

## 4. Open questions for the owner

1. **Reverse the 2026-10-04 ruling** that only a `Fresh` home mints a device
   link (065 `:193`)? If the answer is yes for the owner principal only,
   the rule can read "`Fresh` or the owner's own resumed home", which keeps
   a member's stolen bookmark unable to mint.
2. **Build the revocation cascade?** Revoking a login does not end the
   logins it issued (`access.gleam:1477-1497`; `ui_sessions` `EndLogin`,
   `:1296-1306`). 2c is unsafe without a transitive `issued_by` cascade.
   Is that worth building for a stopgap, given passkeys do not need it?
3. **Should a passkey sign-in be `Fresh`?** If not, a phone signed in with a
   passkey cannot open the admin page or mint a device link without going
   back to `loom ui`. If yes, a stolen unlocked phone with Face ID bypass
   matters more, and the passkey should require user verification
   (assumed above).
4. **Which authenticators must work?** iCloud Keychain passkeys on the
   phone and laptop, a hardware key, a password manager? Each differs in
   counter behaviour and algorithm; refusing everything but ES256 is
   proposed.
5. **One owner or several?** The proposal registers passkeys against a
   principal, so members could also use them. Restrict to the owner at
   first?
6. **Do you run sessions on this box with a network setting other than
   `full`?** The default is `full`, which makes 2a on loopback unsafe. I
   assumed you use the default.
7. **Unix-socket listener for the view.** Worth forking glisten and mist for
   2a? I assumed not.
8. **The ts.net name stability.** A passkey is bound to the rpId. Renaming
   the node or the tailnet orphans every passkey. Is a fixed name
   acceptable, or should the daemon keep the list of rpIds it has issued?
