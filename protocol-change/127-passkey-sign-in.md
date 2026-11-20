# protocol-change/127: signing in to the web view with a passkey

**Status**: PROPOSED 2026-11-20. Option 2b of
[`docs/design-notes/phone-sign-in.md`](../docs/design-notes/phone-sign-in.md),
chosen by the owner on 2026-11-20.
**Affects**: four new routes under `/ui` and two new script assets; a new
catalogue table (`access_passkeys`, catalogue version 23); a new
direct dependency of `client` (`kryptos`); a new field on the home component's
start record (`web_view/home.Start.passkeys`) and a new region of the account
panel. No `v2` frame, `loom.toml` key or control command changes, and no
interface frozen in the implementation spec's Part 1 changes.
**Raised by**: the owner, who runs the distributed daemon on a box and wants to
reach its home from a phone without opening a shell on the box to run `loom ui`.
**Builds on**: [065](065-web-workspace-mode.md) (the browser login, the claim,
the `Fresh` and `Resumed` origins), [051](051-web-view-route.md) (the route
checks, the content security policy, what a socket admits) and
[052](052-web-view-remote-origin.md) (the listed `https` origins a phone reaches).

## Problem

Every way into the web view starts from a credential the daemon has already
issued, and the first one for any browser comes from `loom ui` on the daemon's
machine (`docs/design-notes/phone-sign-in.md`, section 1). For a daemon on a box
reached over a tailnet, the owner at a phone must first open a shell on the box.
A login also ends thirty days after it was made, so the shell is needed again at
least monthly for every browser.

## What was considered

The design note compares five options and its recommendation was to build
passkeys. In short:

- **Tailnet identity headers** (2a) trust a header any local process can write to
  the loopback listener, and under the default `network = "full"` a session's own
  agent is such a process. Rejected.
- **A device link from a resumed home** (2c) and **a pairing code approved from a
  signed-in browser** (2d) move trust from "was at a shell recently" to "has a
  browser whose login is still valid". They need a signed-in browser to exist and
  a revocation cascade that does not. Deferred.
- **A passkey** (2b) needs nothing from the owner's other browsers, and its
  signature cannot be forged from the loopback listener without the private key.

Within 2b these were also considered.

### A `begin` request for each challenge

The usual shape is a `POST` that returns the challenge as JSON and a second `POST`
that carries the result. It needs `connect-src 'self'` on both pages, a JSON body
decoder for each route, and a header or a body field to carry the page nonce.
Rejected. The page itself is a navigation the daemon answers, so it carries the
challenge as a data attribute, and the one `POST` is an ordinary form the
existing `form-action 'self'` policy already allows. The policy for these pages
differs from the resume page's by nothing.

### A passkey list on a separate page

A fixed document at `/ui/p/<key>/passkeys` could list, add and remove. Rejected
because the home's account panel already lists the owner's sign-ins and ends
them, and a person who looks for a passkey looks there. Only the page that runs
`navigator.credentials.create` is separate, because it needs a script.

### Other algorithms and attestation

Supporting RS256 or EdDSA would need a COSE reader, and attestation formats
would need a trust store for vendors. The daemon has one owner and no vendor to
trust. It accepts ES256 and attestation `none`, and says so on the registration
page. A person whose authenticator offers only another algorithm is told that.

## Decision

### Who may register, and who may sign in

Only the daemon's owner, for now. A registration is accepted only from a page
that is the owner's, was opened at `Operator` ceiling, and is `Fresh`: that is, a
`loom ui` exchange the owner made in the last eight hours. The daemon refuses a
registration from any other page, and refuses to sign in a passkey whose
principal is not the owner. A member is not offered the control and the route
refuses a member's page.

### Routes

All of them are under `/ui`, so the router's host check, the rebinding defence,
runs first as it does for every route (051).

| Route | Method | Answers |
|---|---|---|
| `/ui/signin` | `GET` | The fixed sign-in document, reachable with no login, with a fresh challenge in a data attribute. |
| `/ui/signin` | `POST` | The sign-in: on success the exchange page of a new home and a `loom_login` cookie, as `POST /ui/l/<key>/home` answers; otherwise the fixed refusal. |
| `/ui/p/<key>/passkey` | `GET` | The registration document, with a fresh challenge, for an owner's fresh operating home. |
| `/ui/p/<key>/passkey` | `POST` | The registration: on success `303` to the home; otherwise the fixed refusal. |
| `/ui/assets/web_view_signin.js`, `/ui/assets/web_view_passkey.js` | `GET` | The two scripts. |

The `GET` of a document is a navigation (`Sec-Fetch-Site` of `none` or
`same-origin`). Each `POST` must be from this origin's own page
(`ui_http.same_origin_post`), declares a form of at most 4096 bytes, and is read
only after that. The registration `POST` also carries the page's nonce, which the
daemon compares in constant time with the page's, exactly as a socket does, so a
program that holds the cookie and the key but not the tab's `sessionStorage`
cannot register. A refusal of the sign-in is one fixed `401` document that echoes
nothing; a refusal of the registration is one fixed `403`.

The `POST /ui/signin` takes a control-class parser permit as the resume does, so
a daemon that is not serving refuses it.

### Challenges

A challenge is 32 bytes from the daemon's entropy source, as 43 base64url
characters. It is issued when the page is served, held by the UI session table
(`ui_sessions`), the actor that already holds every other per-page secret, and
redeemed by one message that removes it, so it is single use for the same reason
a ticket is. It lives five minutes. The table holds at most 64: a new challenge
at the bound removes the one that would expire first, so a stranger who loads the
sign-in page cannot grow the table, and the cost of loading it a hundred times is
that an earlier visitor's page must be reloaded. A registration challenge names
the principal that asked for it, and the redemption must find the same principal.

The daemon reads the challenge from the posted client data, redeems it, and only
then looks anything else up. A replayed, expired, unknown or other-purpose
challenge is refused before a credential or a signature is touched.

### The ceremony

`client/daemon/passkey` holds the checks as pure functions. In order, for a
sign-in: the client data has `type` `webauthn.get`, the issued challenge, an
`origin` equal to the page's origin byte for byte, and no `crossOrigin: true`; the
authenticator data has the SHA-256 of the relying party id, the user-present and
user-verified flags; the signature, ES256, verifies over the authenticator data
followed by the SHA-256 of the client data under the stored key; and the counter
increased, unless both it and the stored counter are zero (synced passkeys never
count). User verification is required: `userVerification: "required"` is what the
page asks for, and the flag is what the daemon checks.

The relying party id is the host of the origin the request was admitted under,
without a port: for a listed origin, the listed host; for a loopback `Host`, the
name the browser sent. A browser refuses an IP address as a relying party id, so
a passkey cannot be registered at `127.0.0.1`; it can at `localhost` and under
`.localhost`. The origin in the client data must equal the page's address
(`ui_http.address`), so a signature made for another service on the same host, or
for the same host on another port, does not verify.

A registration is checked the same way with `webauthn.create`, and the attested
credential data must name the credential id the browser posted. The key arrives
as the browser's `getPublicKey()`, `SubjectPublicKeyInfo` DER, which `kryptos`
parses and whose curve it names; a key that is not P-256 in 91 bytes is refused.
The daemon has no COSE or CBOR reader and adds no `@external`.

### Storage

Catalogue version 23 adds `access_passkeys`: credential id (primary key), the
principal, the public key as base64url text of the 91-byte DER, the signature
counter, a label of one to thirty-two printable ASCII characters, when it was
registered and when it last signed in. A principal holds at most eight. Every row
is decoded totally on read: a row that does not decode is `Invalid`, never a
passkey. Removing a passkey names it by a fingerprint (sixteen hexadecimal digits
of the SHA-256 of its credential id) and searches only the caller's rows.

### The page and its policy

`/ui/signin` and `/ui/p/<key>/passkey` are fixed documents with no inline script
and no inline style, served under the policy the resume page has: `script-src
'self'`, `form-action 'self'`, and nothing wider. The script reads its inputs from
data attributes the daemon wrote, calls `navigator.credentials.get` or
`create`, puts the base64url results in the form's hidden fields and submits it.
There is no `fetch`, so `connect-src` is unchanged. The Mermaid frame's
`sandbox` policy is not used, since a sandboxed document without
`allow-same-origin` has an opaque origin and WebAuthn fails there.

### The home's account panel

The panel gains a region, "Passkeys". It lists the owner's passkeys with each
label, when it was added and when it last signed in, with a "Remove" button that
asks for a second press, "Confirm", before it acts. On an owner's fresh operating
home it also draws "Add a passkey", a link to the registration page. The region is
beneath `home.signins_path`, where the home's socket already admits a click, so
the socket's admission is unchanged. Removal is the daemon's own check, made
again when the request runs: the page must belong to the owner at `Operator`
ceiling. The new routes extend what a browser may do under `/ui`, and the
addendum to [051](051-web-view-route.md) of this date lists them.

### The root page

The document at `/` names the sign-in page for a browser with no login, beside
`loom ui`.

## Frozen-interface impact

None of Part 1. The change adds HTTP routes and assets under the web view's own
prefix, one catalogue table behind the migration mechanism, and a field on an
in-process record. `loom.toml` has no new key: the origin the daemon trusts is
the one `[daemon] ui_origins` already lists.

## Cost

- **A new dependency.** `kryptos` is already locked through `gose`; `client`
  names it. `conformance` and `eval` build against `client`, so their manifests
  gain the requirement line.
- **A synced passkey is as safe as the account that syncs it.** The daemon
  cannot tell a hardware key from a passkey in a cloud keychain, because
  attestation is `none` by decision.
- **A rename orphans every passkey.** A passkey is bound to the host. Changing
  `[daemon] ui_origins` to another host leaves the stored credentials unusable,
  and the owner registers again from `loom ui`.
- **`loom ui` stays.** It is how the first browser signs in, how a fresh home is
  opened, and the recovery path for a lost passkey.
- **No end-to-end check without a browser.** The daemon's half is tested with
  keys made in the tests. What a phone's authenticator sends needs a phone.

## Verification required

- The pure checks refuse each way a ceremony can be wrong: another origin, another
  relying party, a clear user-present or user-verified flag, another challenge or
  ceremony, a counter that did not increase, a key of another curve or size, a
  signature of another key or over changed data.
- A challenge is single use, expires, and is refused for another purpose.
- The routes refuse a cross-site or origin-less `POST`, an oversized or chunked
  body, a missing field, a page that is not the owner's fresh operating home, a
  wrong nonce, and each unknown credential, with the fixed document.
- A good sign-in answers with the exchange page of a new home and the login
  cookie, the login row is written, and the sign-ins list shows it.
- The account panel lists, offers Add only on a fresh owner home, and removes only
  after the second press.

## Provisional ruling: a passkey sign-in opens a resumed home

A home that a passkey signs in is `Resumed`, the origin the bookmark gives, and
not `Fresh` (`ui_sessions.passkey_origin`). It lists and opens sessions, and it
can list and remove the owner's passkeys and sign browsers out. It cannot start the
admin page, make a device link or register a passkey, which need a `loom ui`
exchange in the last eight hours.

The owner ruled on 2026-11-20 that this is provisional. The case for `Fresh` is
that a user-verified assertion proves more than a `loom ui` ticket does, since it
needs the authenticator and the person, and without it a phone that signed in with
a passkey can never manage people or link another device without going back to a
shell. The case for `Resumed` is that [065](065-web-workspace-mode.md) ruled that
only a `loom ui` exchange is fresh, so a stolen phone with its biometric
bypassed, or a passkey synced to a compromised account, opens no more than a
stolen bookmark does. The ruling is one constant and this paragraph; to flip it,
change `passkey_origin` to `Fresh` and amend the paragraph and 065's rule that
only a `loom ui` exchange mints a fresh home.

## Passkeys outlive logins

A passkey is a row keyed by its principal, not a login. "Sign out everywhere",
deleting the root key (which revokes every login at the next start) and rotating
the owner's credential do not touch it, so a passkey must be removed by hand. The
account panel's Passkeys list is where the owner checks for a key they do not
recognise. Removing a passkey does not end the logins it signed in: those
browsers stay signed in until they are signed out from the Sign-ins list, and the
notice after a removal says so. This is deliberate. A login is the thirty-day
credential a sign-in earned, and ending it with its passkey would need the login
row to name the passkey, which it does not.

## The root key and the passkey table

The owner ruled on 2026-11-20 that deleting the root key does not clear
`access_passkeys`. A passkey is removed by hand from the account panel, and
nothing else removes one. A lost root key therefore leaves every passkey able to
sign in again, which is the point: the passkey is how the owner gets back in
without a shell on the box. An owner who suspects a key they do not recognise
removes it from the Passkeys list.
