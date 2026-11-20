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

So the first browser ever signed in must come from `loom ui` on the box, and
every later browser must come either from a shell on the box again or from a
*fresh* home, which is a home the person opened with `loom ui` within the
last eight hours. A laptop whose login was resumed from its bookmark
cannot sign the phone in. In practice the owner is at a shell on the box
whenever the phone needs access.

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
cannot, from the request alone. The headers are ordinary request headers
arriving on a listener that any process on the box can connect to. The
options are:

1. *Trust the loopback listener.* Accept the headers, since Serve is the
   only thing that is supposed to connect. This fails the 051 model: a
   session whose tools have network access runs `curl -H
   'Tailscale-User-Login: user@github' http://127.0.0.1:4100/...` with the
   listed `Host`, and obtains the owner's login. A login for the owner is
   owner authority (`protocol-change/065-web-workspace-mode.md:893-896`).
   Sessions run with `--network off` would be safe, but that is not the
   default.
2. *Serve to a unix socket.* Serve can forward to `unix:/path`. *(inference.)*
   Filesystem permissions on the socket then replace the loopback port as
   the gate, and the session sandbox, which jails the filesystem, would not
   reach it. This requires the daemon to listen on a unix socket for the
   view, and `mist`, the HTTP server it uses, to support that. I did not
   check whether it does. If it does not, this is new listener code and
   probably new FFI.
3. *Bind the tailnet address and verify with `whois`.* The daemon listens
   on the node's `100.x` address, reads the real peer address, and asks
   `tailscaled`. That is robust. It has no TLS, so the page is not a secure
   context: `__Secure-` cookies and `Secure` are unusable, WebAuthn is
   unavailable, and the origin model of protocol-change/052 does not
   apply. It is a different product from the one built.

**What it trusts.** `tailscaled` on the box, the tailnet's own login and
device authorization, and, in option 1, the absence of any hostile local
process.

**Code it needs.** A config key and its validation; a source of the
tailnet identity (a header read, or a call to `tailscale whois --json`
through a spawned process, or the LocalAPI over its unix socket, which needs
a client for HTTP over a unix socket that `gleam_httpc` is not *(inference)*);
a route or an extra branch in `server.web_view` (`server.gleam:568`) that
calls `ui_login.issue` for the owner; and tests.

**Cost.** Smallest UX of any option, and the only one needing nothing from
the owner's laptop. The cost is the trust in the headers. Unless the
daemon listens where a hostile local process cannot reach it, a session's
agent can obtain the owner's thirty-day login. I would not build 2a on the
loopback listener.

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

**What OTP provides.** `crypto:verify(ecdsa, sha256, Message, DerSignature,
[PublicPoint, secp256r1])` verifies an ES256 signature, and
`crypto:hash(sha256, _)` does the hashing. `gleam_crypto`, which both
`client` and `storage` already depend on (`packages/client/gleam.toml:38`,
`packages/storage/gleam.toml:12`), covers hashing and HMAC; I do not
believe it exposes ECDSA verification *(inference; check `go doc`-style
with `gleam docs` before settling)*. So the design needs **one**
`@external`, to `crypto:verify`, in one `internal/ffi_*.gleam` module with
the comment the style rule requires. That is the minimum the rule allows:
gleam_stdlib, gleam_erlang, gleam_otp and weft cannot verify a signature.
No new Hex dependency is needed.

Parsing is where a dependency could be avoided. The browser's
`AuthenticatorAttestationResponse.getPublicKey()` returns the credential
public key as SubjectPublicKeyInfo DER, and `getAuthenticatorData()` returns
the authenticator data bytes, so the page can send both and the daemon does
not need a CBOR or COSE decoder. A fixed-prefix check of the 91-byte P-256
SPKI, then the 65-byte uncompressed point, is a pure-Gleam function.
Browsers new enough for passkeys ship both methods *(inference)*. If the
owner wants to support an authenticator that returns another algorithm, a
COSE reader is needed; I would refuse everything but ES256 and say so on the
registration page.

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
targets, like `host/login`); the single FFI function; one asset script and
its policy; a "Passkeys" list with delete in the account panel beside
"Sign-ins" (`web-view.md:1700-1708`); the root page's text for a browser
with no login (`web-view.md:1964-1990`) pointing at the sign-in page.

**Cost.** The largest build here: a migration, a new credential class
beside `bearer` and `browser` (065 added the kind column so this is
anticipated, `065-web-workspace-mode.md:893-896`), an FFI function, and
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
(`:880-921`): "A stolen fresh home is worth a login", and the generalisation
that a *resumed* home able to make another login lets one stolen bookmark
mint a second credential, which the owner cannot tell from the first except
in the sign-in list. The owner ruled the `Fresh | Resumed` origin on
2026-10-04 (`:910`, `:921`). The cost section names the limit: a stolen
login can do everything a resumed home can for thirty days "but no admin
page and no device link, which only a fresh home mints" (`:755-757`).

**What has changed since.** The review also fixed the part of the risk
that was about lifetime. A device-link login inherits the issuing login's
expiry and names it as parent (`ui_socket.gleam:3200-3210` doc, passing
`standing.login` at `:3274-3280`; `065:921`), and the grant allowance
(three an hour) applies (`:757-759`). So a stolen bookmark cannot extend
its own thirty days by minting children. What remains is that the thief
holds a *second row* that survives the owner revoking the first, unless
revocation of a parent also ends its children. I have not verified whether
`revoke_login` follows the parent link, and that decides how serious
the residual is. *(open: see section 4.)*

**What it trusts.** That the person holding a resumed home is the owner. It
adds no new factor; it moves trust from "was at a shell within eight
hours" to "has a laptop whose bookmark is valid".

**Code it needs.** Remove the `Resumed` arm in `device_link_for`
(`ui_socket.gleam:3231-3236`), let the home draw the control
(`view/signins`), update the tests that assert a resumed home is refused,
and amend 065 with an addendum for the new ruling. No storage change.

**Cost.** Small. It solves the phone only when some browser of the owner
already has a login, and the very first browser still needs `loom ui` on
the box once. It also weakens the 2026-10-04 ruling, which is the owner's
to change.

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

1. **Now: 2c, if the owner reverses the 2026-10-04 ruling; otherwise skip
   to 2b.** It is a deletion plus tests, and it answers the stated case
   when any laptop browser is already signed in. It needs an **addendum to
   `protocol-change/065`** (the ruling is its own) and no new number. I
   would only do it after confirming that revoking a login also ends its
   children (section 4, question 2), because that is what makes the
   weakening bounded.
2. **Next: 2b, passkeys.** It is the option that matches the request ("use my
   passkey"), needs no shell and no already-signed-in browser, and defends
   against the agent threat model that rules out 2a. It needs a **new
   protocol-change at the next free number** (127 if branch 126 lands first;
   check `ls protocol-change` at filing): the credential table and
   catalogue migration, the three routes, the challenge lifetime, the
   `Fresh` ruling for a passkey sign-in, and the one FFI function with its
   justification. Staged as: pure verification and the FFI with property
   tests; the table and registration from a fresh home; the sign-in page
   and the account panel list.
3. **Not now: 2a**, until the daemon can be reached by Serve through a
   socket that a session's tools cannot connect to. If a unix-socket
   listener is added for other reasons, 2a becomes a small addition on top
   and would be its own protocol-change.
4. **2d only if** the owner wants the phone to initiate. It is 2c with more
   code and the same trust.

Whatever is built, `loom ui` on the box stays as the recovery path for a
lost passkey and as the only way to sign in the very first browser.

## 4. Open questions for the owner

1. **Reverse the 2026-10-04 ruling** that only a `Fresh` home mints a device
   link (065 `:193`)? If the answer is yes for the owner principal only,
   the rule can read "`Fresh` or the owner's own resumed home", which keeps
   a member's stolen bookmark unable to mint.
2. **Does revoking a login end the logins it issued?** I did not trace
   `manager.revoke_login`. If it does not, 2c lets a stolen bookmark leave a
   surviving row after the owner revokes, and the answer to question 1 should
   depend on it.
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
6. **Is `--network off` the default for sessions you run** on this box? It
   decides whether 2a on loopback is tolerable at all. I assumed not.
7. **Unix-socket listener for the view.** Is it worth building for 2a? I
   did not check that `mist` supports it.
8. **The ts.net name stability.** A passkey is bound to the rpId. Renaming
   the node or the tailnet orphans every passkey. Is a fixed name
   acceptable, or should the daemon keep the list of rpIds it has issued?
