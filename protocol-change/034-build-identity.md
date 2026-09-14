# protocol-change/034 — build identity on the control wire

**Status**: PROPOSED 2026-09-14 · **Affects**: the control-plane `hello`
body and the private daemon endpoint record (Part 1.6 client protocol, as
frozen by [015](015-daemon-control-and-session-attachments.md)) ·
**Implemented**: `host/build_identity`, `host/endpoint`, `client/daemon`,
`tui/daemon`, `tui/bootstrap`

## Problem

One daemon serves many workspaces and outlives the terminal that started
it. An update installs a new release *beside* the old one while the old
daemon keeps running (issue #392), so the common state after `make
install` is a new client against an old daemon. Nothing on the wire said
which build either side was: the `hello` carried a protocol version, a
daemon epoch, an authenticated principal and input limits, and the
endpoint record carried the same plus the native fence. A client compared
none of it, so it attached silently to a daemon several releases older
than itself and the operator found out when a frame the client sent was
refused or rendered wrong.

The protocol *version* does not answer this. It changes only when the
wire shape breaks, which is exactly when it is least useful; two builds
on the same protocol version are the interesting case, because they
attach happily and misbehave subtly.

## Proposal

**1. The hello names the daemon's build.** The `hello` body gains two
optional string fields:

```
hello { protocol: 2, epoch, principal, build_version, build_commit, limits:{...} }
```

`build_version` is the release version (`0.1.0`) and `build_commit` the
git commit the daemon's tree was built from (`4c266dde`), both as the
launcher that started the daemon exported them. A tree built with no
release metadata — `gleam run`, a hand-built checkout — names `dev` and
`unknown` honestly rather than inventing a version.

**2. The fields are additive and optional, not version-gated.** A daemon
that predates this proposal omits both; a client reads the absence as
"unknown build" and says so rather than refusing the frame. The version
comparison exists to *inform* an operator, not to gate an attach, so a
new client must be able to complete a handshake with an old daemon in
order to report that it is old. That is the whole point and it sets the
compatibility direction: new-client-versus-old-daemon works and reports;
old-client-versus-new-daemon ignores two unknown keys, which the control
codec already tolerates.

**3. The endpoint record carries the same identity, at schema version
two.** `Ready` gains an optional build identity and the record's `version`
becomes `2` when it is present, staying `1` when it is not. `decode`
accepts both: a version-one record (nine keys) reads with no identity, a
version-two record (eleven keys) requires both fields. The endpoint
record is private to a host, not a wire shape, but it moves in lockstep
with the hello because a launcher reads it to decide whether a daemon is
alive *before* opening a control socket, and that decision benefits from
the same fact.

**4. Mismatch is reported, not refused.** A client that reads a daemon
build different from its own writes one line naming both — `daemon build
0.1.0 (4c266dde) differs from this client's 0.2.0 (abcdef12)` — and
attaches anyway. The two halves are protocol-compatible by construction;
the line tells the operator which binary is which and that a restart
picks up the update. Nothing is refused on the strength of a version
string, because the version string is not what decides compatibility.

## Impact

`host/build_identity` (new) reads the two environment variables the
launchers export (`LOOM_BUILD_VERSION`, `LOOM_BUILD_COMMIT`) and models
them as one `Identity`. `host/endpoint` threads it through `Ready`,
`encode`, `decode` and `publish_ready`. `client/daemon/server` emits it in
the `hello` and `client/daemon/main` passes it to `publish_ready`.
`tui/daemon/protocol` decodes it into a `Build`, and `tui` compares it
against its own identity at attach and appends one System line.

The launchers — `scripts/release.sh`, `scripts/release-client.sh`,
`scripts/install.sh` and the `run-server`/`run-tui` Makefile targets —
each export the two variables before `exec`, with the values baked in at
build time so a release runs on a host with no git and no checkout.

## Alternatives considered

**Put the version in the daemon epoch.** Rejected: the epoch is opaque,
minted per daemon lifetime, and a client has no epoch of its own to
compare against. Turning it into a structured value would change what
every lifecycle request carries.

**Bump the protocol version and refuse a mismatch.** Rejected for the
reason above: refusing is the one behaviour that makes the diagnosis
impossible. An old daemon and a new client on the same protocol version
are exactly the pair this proposal exists to describe.

**Read the version from the installed tree instead of the environment.**
Rejected: the daemon's `code:root_dir()` is pinned to the physical
release directory it started from, which is precisely what makes it *the
old one* after an update. Reading the current symlink would report the
new version for a daemon still running the old code.

## Decision

**Accepted 2026-09-14.** The owner approved the additive, report-don't-
refuse shape: it is the only one under which a mismatch is visible at all.
The version comparison is a diagnostic, not a gate, and the compatibility
direction it fixes — new client, old daemon, reported — is the one an
update actually produces.
