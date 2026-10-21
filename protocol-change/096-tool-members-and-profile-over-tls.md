# protocol-change/096: tool members, and profiling over TLS distribution

**Status**: ACCEPTED 2026-10-21. The owner asked for `[daemon] profile = true`
to coexist with `[distribution]` and for an attaching tool to join over TLS
(issue #1050), with nothing in the tool that names Loom.
**Affects**: no Part 1 interface. The `role` of a membership ledger `member`
entry ([086](086-membership-ledger.md)) gains one word, `tool`. `loom
distribution` gains `attach-file`. The profile launcher
(`scripts/profile-launcher.sh`) changes what it starts for a distributed
daemon. Plans and bundles are unchanged and still know only `orchestrator`
and `executor`.
**Raised by**: issue #1050, where a daemon with `profile = true` and a
`[distribution]` table fails to start with "[distribution] is configured but
this VM already runs distribution".
**Builds on**: 078 (the trust check on the TLS handshake), 086 (the ledger
and its pin table).

## Problem

`profile = true` makes the launcher boot the VM with `-name`, over plain
distribution, with a throwaway cookie in a private `HOME`. A distributed daemon
has to boot unnamed with `-proto_dist inet_tls` and then name itself from its
ledger entry (`distribution.start` refuses a VM that is already distributed),
so the two settings cannot both hold, and an operator joining a daemon to a
deployment had to give up profiling.

The tool that attaches (pickglass, Observer, `erl -remsh`) joins as a
distributed node, so on a TLS deployment it must pass the daemon's handshake
like any peer: a certificate that chains to the deployment's authority, whose
SHA-256 is in the daemon's pin table, and which carries exactly its node name.

## What was considered

### A probe certificate minted by the daemon at boot (rejected)

The issue proposed a short-lived self-signed certificate written to the
profile token directory and accepted by a special case in the verify callback:
loopback peers only, hidden nodes only, names starting with `loom_probe_`. It
needs a second trust path in the callback that protocol-change 078 and 086
work to keep to one, three conditions that each have to be right, and a
pickglass that knows where Loom keeps the file.

### Enroll the tool in the ledger (accepted)

The deployment already has an authority, a way to mint a certificate under it
(`enroll`), and a pin table the callback reads. A tool is one more node the
operator lets in, and revoking it is a ledger entry. The callback does not
change. What the tool needs is standard: an `ssl_dist_optfile` and the
cookie. Any Erlang node can use those, so no tool needs a Loom setting.

### Enroll the tool as an `orchestrator` (rejected)

It needs no format change, but the ledger, the holdings query a revoke makes
and the peer roster treat every orchestrator as a Loom daemon that can be asked
what it holds. A tool answers nothing, so every revoke of it would be
"unknown" and need `--force`, and the roster would try to dial it.

## Decision

### The `tool` role

A `member` entry's `role` is `orchestrator`, `executor` or `tool`. A tool:

- holds no workspace and runs no session, and no daemon dials it for peer
  mail, the session directory or a move;
- is never in the session directory (`directory` is `none`);
- lists the daemons it attaches to in `links`, at least one, and no member
  lists a tool. `enroll` and `attach-file` refuse the other direction, so the
  daemon's pin table holds the tool only through the tool's own link;
- is revoked with `revoke`, which checks no holdings for it, and is never
  `renew`ed: a tool's key is not kept in a bundle, so a new certificate means
  `revoke` and `attach-file` again.

The fold is otherwise unchanged. Node-name and pin uniqueness, the 64 active
members and the 256 names apply to tools too.

### `loom distribution attach-file`

```
attach-file NAME --node N --links DAEMON --out DIR [--host H] [--force]
            [--wait SECONDS] [COMMON]
```

It does what `enroll` does for a `tool` (mint under the kept authority, sign,
append, hand to a daemon, report confirmations) and writes, instead of a
bundle, `DIR/ca.pem`, `tool.pem`, `tool.key`, `.erlang.cookie` and
`ssl_dist.conf` (the directory is mode 0700, the key and cookie 0600). The
options file is plain Erlang: a `client` section with the three credential
files, `verify_peer` against the authority and the TLS versions, and no Loom
function in it. It has no `server` section, because a tool must never be
dialled (see What it costs). The report prints the flags that use it:

```
HOME=DIR erl -proto_dist inet_tls -ssl_dist_optfile DIR/ssl_dist.conf \
    -name N -hidden -dist_listen false -remsh DAEMON_NODE
```

The tool must run as the node `N`, the name its certificate was issued for and
its ledger entry records. The verify callback checks the certificate against
the pinned name, and then `ledger_trust` drops any connected node whose name is
not a linked active member's (its `node_up` check), so a tool that starts under
another name connects and is disconnected at once.

## What it costs

- **A format word.** A daemon that does not know `tool` refuses the tool
  entry as malformed, and because the ledger is a chain it then refuses every
  entry after it too, revokes included, until it is upgraded. Every daemon in
  a deployment must run this release before the operator signs a tool, and the
  operator should check that every daemon confirmed the entry (`--wait`, and
  the report's list) before relying on a later entry. A daemon installed from a
  bundle whose ledger carries a tool line, on an old release, refuses to start
  and names the line.
- **A tool must never listen.** The options file trusts the authority and not
  the ledger, so a listening tool would accept a member that was revoked, and
  that member could reach the daemon through the tool's pinned connection. The
  file therefore has no `server` section, and every printed recipe adds
  `-hidden -dist_listen false`.
- **A tool is a full Erlang node.** Whoever holds its files can call any
  function on a daemon it is linked to, as any peer can (078). The enrollment
  is the grant, and it is a visible, revocable ledger entry; the cookie it
  carries is the deployment's, so the files are as sensitive as a bundle.
- **`loom observer` and `loom-profile` do not find a distributed daemon.**
  They match a generated node name and a private cookie directory, and a
  distributed daemon has neither. Observer and pickglass attach with
  `attach-file`.
- **The node name is fixed.** A tool that picks a random name for each run
  cannot be enrolled by name; pickglass takes `--name` for this.
