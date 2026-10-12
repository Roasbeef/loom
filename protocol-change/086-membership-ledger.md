# protocol-change/086: a signed membership ledger for distribution

**Status**: PROPOSED 2026-10-11. Nothing here is built, and every spelling is
provisional until phase 1 lands.
**Affects**: the `[distribution]` table of `loom.toml` (one new key, `ledger`,
exclusive with `[[distribution.peers]]`), the text of the TLS options file and
the semantics of the `OptionsMismatch` boot check in ledger mode, the TLS
verify callback (`verify/4`, which reads a live table), the `Membership` value
that `distribution.start` returns (it becomes live), the daemon's fault
vocabulary for distribution (three new faults), the bundle format (a new
marker, `loom-distribution-bundle/2`; `/1` is unchanged), a new durable file
format (`loom-membership-ledger/1`), a new registered process and closed
message type on every node with a ledger (`loom_ledger`), the client control
protocol (Part 1.6: three new owner-only commands, `ledger.append`,
`ledger.entries` and `ledger.status`), the operator command `loom distribution` (five commands
added; `provision` writes a ledger), the node-name atom rule, and, in later
phases, the reference checks of `[executors.<name>]`,
`[orchestrators.<name>]` and `[directory] members`. `protocol.version`, the
executor host's `HostMessage`, `OwnerMessage`, the orchestrator port's
`Message`, the catalogue schema, the execution ledger, the helper wire and
`system.json` (`loom-distribution-system/1`) do not change.
**Raised by**: the owner's request of 2026-10-11 to add and remove nodes of a
distributed deployment without reprovisioning every node, driven by laptops
that come and go as spawners for remote subagents
([protocol-change/084](084-remote-subagents.md)).
**Design**: [docs/design-notes/membership-ledger.md](../docs/design-notes/membership-ledger.md).
**Builds on**: [protocol-change/078](078-distributed-runtime.md) (pinned TLS
distribution, provisioning, bundles) and, where present,
[083](083-khepri-session-ownership.md) (the Khepri directory, PR #934) and
[085](085-distributed-admin-surface.md) (`deployment.status`). Phases 1 and 2 need
neither. Phase 3 amends 083 for member daemons.

## Problem

Trust in a distributed deployment is a list of pins: the SHA-256 of each peer's
leaf certificate and the node name it must present. `provision` writes the list
into every node's bundle, `install` renders it into the options file the VM
reads once at boot, and `provision` drops the authority key. Nothing can be
added, removed or renewed afterwards without provisioning again, which replaces
every bundle and restarts every node.

That cost is acceptable for a fixed pair of machines. It is not for laptops that
are added, lost and replaced. The remote subagents design records the current
revocation procedure as removing the pin from `[[distribution.peers]]` on every
node and restarting them. Three further facts bound a solution. The
`net_kernel` allow list can only grow, so it cannot carry a removal. TLS checks
a pin only at handshake, so removing a pin does not end a connection that exists.
And the trust graph is not a full mesh: an executor pins only the orchestrators
that use it, which a replacement must keep.

## What was considered

**Reprovision, as today.** Correct and the reference behavior. It is the
problem.

**Trust any certificate chained to the authority, with a revocation list or
short-lived certificates.** It solves admission and leaves membership. Nodes
still need a roster to know whom to dial, which executors an orchestrator may
use and who is a Ra voter, and the roster is the ledger. A revocation list has
the same transport and freshness problem. Short-lived certificates turn
revocation into "stop renewing", which takes effect at expiry and needs a renewal
service a sleeping laptop cannot reach on schedule.

**A pin list pushed by the operator to each node.** No signature to tell the push
from another control command, no chain so no catch-up for a node that was off,
no history, and it needs the operator to reach every node at once.

**The ledger stored in Khepri.** A majority-committed write and a consistent read
of freshness. Against it: the pins that let a voter reach the store come from the
ledger, so a file and a transport must exist anyway; not every deployment has a
directory; a write needs a majority at the moment a revoke may be most urgent; the
store is not signed; and it is a second mechanism. Rejected, and the Ra voter set
follows the ledger instead (phase 3).

**A quorum of signers.** Rejected until a deployment has more than one operator.

**A signed append-only log spread by anti-entropy.** This is the decision.

## Decision

### The ledger file

A ledger is a file of lines separated by `\n`. A line is

```
<body> "." <signature>
```

where `body` is the unpadded URL-safe base64 of the entry body and `signature` is
the unpadded URL-safe base64 of the DER ECDSA signature. A reader MUST reject a
line with padding, whitespace inside the line, more than one dot, a body over
4096 bytes after decoding, a signature over 80 bytes after decoding, or a half
that is not the canonical encoding of its bytes (its unused trailing bits are not
zero). Without that last rule a flipped trailing character decodes to the same
bytes, so the text of a line could change while the entry, its identity and its
signature did not. An
unterminated last line (no `\n`) is a write that did not finish; a node discards
it at boot and never acknowledges it.

The **body** is UTF-8 JSON, written by the signer with the keys in the order
shown and no insignificant whitespace. A verifier MUST NOT re-serialize it. It
verifies the signature over the bytes it received, then decodes those bytes with a
total decoder that requires exactly the keys of the entry's kind and refuses any
other.

The **signature** is ECDSA over P-256 with SHA-256 of the bytes
`"loom-membership-ledger/1" 0x00 body`. The verifying key is the public key of the
authority certificate named by the genesis entry, which every node holds as its
`ca` file. Certificate validity dates are not consulted for ledger signatures.

The **identity** of an entry is the SHA-256 of its body bytes. The signature is
not part of the identity.

Every body has these keys first:

| Key | Type | Meaning |
|---|---|---|
| `format` | string | `loom-membership-ledger/1`. A reader refuses any other value and reports `unsupported_format`. |
| `seq` | integer | 0 for genesis, then one more than the previous entry. |
| `prev` | string | 64 lowercase hex characters, the identity of entry `seq - 1`; 64 zeros for genesis. |
| `time` | string | UTC, `YYYY-MM-DDTHH:MM:SSZ`, the signer's clock. Informational. No rule reads it. |
| `kind` | string | `genesis`, `member` or `revoke`. |

**`genesis`** (`seq` 0 only) adds:

| Key | Type | Meaning |
|---|---|---|
| `deployment` | string | 32 lowercase hex characters, random. |
| `authority` | string | 64 lowercase hex characters, the SHA-256 of the DER of the authority certificate. |

**`member`** adds:

| Key | Type | Meaning |
|---|---|---|
| `name` | string | The plan name: the bundle name, and the default `[executors.<name>]` key. |
| `node` | string | The full Erlang node name, valid under `distribution.check_node_name`. |
| `host` | string | The host other machines reach it at. |
| `listen_port` | integer | Optional; 1 through 65535. |
| `role` | string | `orchestrator` or `executor`. |
| `directory` | string | `voter`, `learner` or `none`. |
| `links` | array of strings | Names of other members this member may connect to. At most 63. |
| `pin` | string | The lowercase hex SHA-256 of the member's leaf certificate. |

**`revoke`** adds:

| Key | Type | Meaning |
|---|---|---|
| `name` | string | The member removed. |
| `pin` | string | The pin it held. Recorded for audit and not compared with the member's. |
| `reason` | string | At most 200 bytes of text with no control character. |

### The fold

The state after entries `0..n` is a function of those entries alone:

- `members`: a map from `name` to its latest `member` entry's fields, with
  revoked names removed. Applying a `revoke` also removes the revoked name from
  the `links` of every remaining member, so a name enrolled again later holds no
  edge it was not given anew.
- `ever`: the set of every `name` any `member` entry has named.

A tool that writes a `member` entry for `enroll` or `renew` derives the member's
current fields, `links` included, from this state and not from the member's last
entry. The last entry still lists a revoked name, and an entry which copied that
list would name a member that is no longer active and be refused as invalid.

An entry is **valid** at state `S` when its `seq` and `prev` follow the head and:

1. A `genesis` is the first entry only, and no other entry has `kind` genesis.
2. A `member` entry's `node` is unique among the other active members, its `pin`
   is not the pin of another active member, `links` names only active members
   other than itself, and with the entry applied there are at most 64 active
   members and 256 names in `ever`.
3. A `revoke` names an active member. Its `pin` is recorded and is not compared
   with the member's.
4. The file holds at most 10,000 entries.

A node that finds a signed entry invalid under these rules refuses it, records
the refusal, and never writes it to the file. The signer's tool runs the same
fold before it signs.

The **pin table** of the node named `n` is the map from pin to node name that
holds, for each active member `m` with `m.name != n`, the pin of `m` when `n`
and `m` are **linked**. They are linked when `m.name` is in the links of `n`, when
`n` is in the links of `m`, or when both have `directory` other than `none`. A
node whose `name` is not an active member has an empty table and starts no
distribution (`NotEnrolled`). Applying a `revoke` that names the node itself
stops its distribution (`Revoked`).

### Accepting an entry

A node given a line while its head is `H` (sequence `h`, identity `i`) does this
in order, and stops at the first failure:

1. Check the size bounds and decode both parts. Failure is `malformed`.
2. Verify the signature. Failure is `bad_signature`. Nothing is parsed before
   this passes.
3. Decode the body. Failure is `malformed`.
4. If `seq <= h`: when the node's own entry at `seq` has the same identity, the line
   is a duplicate and is ignored; otherwise it is a `fork`.
5. If `seq > h + 1`, the line is a `gap` and is ignored; the sender is asked for
   the entries between.
6. If `prev != i`, the line is `chain`.
7. Check validity (the fold). Failure is `invalid`.
8. Append the line to the file and flush it to disk.
9. Publish the new pin table.
10. Disconnect every connected node whose name is not in the new table.

A line that fails at `bad_signature`, `malformed`, `fork`, `chain` or `invalid` is
refused. The node records the last refusal (the sequence number, the failing step
and, for a fork, both identities) and reports it through `ledger.status`, `log` and
its own log; the next refusal replaces it. A refusal changes nothing else. The
node keeps its table and keeps applying entries that extend its own chain, so a
branch it refused cannot block the operator's next entry. A refused line is not
relayed, and `Head` carries only the identity of an applied chain. A `gap` or a
duplicate is not a refusal. The procedure for a node that took the wrong branch
of a fork is in the design note: stop the daemon, truncate the file to the lines
before the fork point, and start it.

The durable append in step 8 precedes the publish in step 9, so a crash between
them replays to the same table. Step 10 disconnects at publish. The process also
subscribes to node-up events with `net_kernel:monitor_nodes` for all node types,
which it needs in any case to send a `Head` when a connection comes up, and on each
node-up it disconnects the node if its name is not in the current table. A
handshake that read the previous table and finishes after the publish is a node-up
that the process handles after the publish, because both are messages to one
process handled in order. No timing assumption is involved.

### The verify callback and the options file

`tls_options` takes a mode. In static mode it renders the pin list as the state of
`verify/4`, as it does today. In ledger mode the state is the atom `live`, and the
text names no pin. The options file in ledger mode is therefore a function of the
credential paths alone: enrolling or revoking does not change it, and the
`OptionsMismatch` check, which compares the loaded file with `tls_options`, is
unchanged in form.

In ledger mode `verify/4` handles the events as today, with one difference for a
leaf. For `valid_peer` it reads the row `pins` of the ETS table `loom_dist_pins`,
whose value is the map from a 32-byte pin to a node name. It returns `{valid, live}`
when the SHA-256 of the leaf's DER is a key of the map and `exact_node_san` holds
for the mapped name, and `{fail, peer_identity_mismatch}` otherwise. When the table
or the row is absent it returns `{fail, ledger_unavailable}`. The table is
`protected`: the ledger process owns it and is the only writer, and the handshake
processes read it. The process replaces the row with one insert, so a handshake
reads the old map or the new one. If the process stops, the table is deleted and
every handshake is refused until it restarts.

### Atoms and the allow list

A node name becomes an atom when the ledger applies a `member` entry that
passed steps 1 through 7, and not before. At most 256 names can be enrolled over
the life of a ledger, so at most 256 atoms. The rule in protocol-change/078 that
peer names become atoms "once, from the finite configuration" becomes "from the
finite, signed ledger". `net_kernel:allow/1` is called with each enrolled name when
its entry is applied and is never reduced; OTP does not support reducing it. A
revoked name stays allowed. The pin table is the check on the certificate, and the
allow list is only a check on the claimed name.

### The `loom_ledger` process and its vocabulary

Each daemon with a `ledger` runs one process registered as `loom_ledger`. It owns
the file, the table and the disconnects, and it is started by the daemon before the
catalogue, after the VM is booted for distribution and before `net_kernel` starts
(the table must exist before the first handshake). Its messages hold integers and
bytes only.

```gleam
pub type Message {
  /// What the sender holds. Sent by both ends when a connection comes up, after
  /// the sender applies entries (to every connected peer but the source), and
  /// every 60 seconds to each connected peer.
  Head(seq: Int, id: BitArray)

  /// The entries after `after`, at most `limit`, which is clamped to 1 through
  /// 64. The reply holds at most 256 KiB of lines.
  Pull(after: Int, limit: Int, reply: Subject(Entries))
}

pub type Entries {
  Entries(lines: List(BitArray), head_seq: Int)
}
```

There is no push message. A node that receives `Head` with a higher `seq` pulls
from its current head and applies the lines in order, through the acceptance steps
above, until it reaches that `seq` or a step fails. The node that is behind always
pulls, whichever end dialed. Equal `seq` with a different `id` is a fork and is
handled as in step 4. A line is accepted from any pinned peer; the sender is not
trusted. Each `Pull` carries a reply deadline of 5 seconds, because a peer in
static mode has no `loom_ledger` process and drops the message without replying.

An orchestrator keeps, for each executor it is linked to, the last `Head` that
executor reported. An executor whose reported `seq` is below the node's head is
pending, and the orchestrator connects to it, with a retry interval of 5 seconds
that doubles to 5 minutes, and sends its `Head`. Only orchestrators dial, and only
executors are dialed this way: a laptop dials in when it wakes, and orchestrators
exchange heads on the connections they already make. A node that applies an entry
which revokes itself also stops this retry.

A node that has no `loom_ledger` process (a static-mode node) drops the
messages, as Erlang drops a send to an unregistered name. A ledger node
therefore lists such a peer as never having reported a head. The vocabulary is
closed and matched without a catch-all, like the orchestrator port's, so a newer
constructor sent to an older node halts it; both ends are upgraded together, and
`format` is the version of the file.

### Control commands

All three are owner-only commands of the client control protocol, Part 1.6.

**`ledger.append`** takes `{"lines": ["<line>", ...]}`, at most 64 lines, and
passes them through the acceptance steps. It replies

```json
{"applied": 2, "head": {"seq": 9, "id": "4c1e..."}}
```

A step failure is refused with `ledger_invalid`, whose message names the step:
`malformed`, `bad_signature`, `fork`, `chain`, `invalid` or `unsupported_format`.
Lines that were already applied before the failure stay applied. A daemon with no
`ledger` refuses with `not_found`.

**`ledger.entries`** takes `{"after": 7, "limit": 64}`, with `limit` clamped to 1
through 64, and replies `{"lines": ["<line>", ...], "head_seq": 9}` with at most
256 KiB of lines. It is the control-protocol twin of `Pull`. The operator's tool
uses it to fetch entries its own copy lacks before it signs.

**`ledger.status`** takes no arguments and replies

```json
{"deployment": "3f9c...", "state": "ok",
 "head": {"seq": 9, "id": "4c1e..."},
 "self": {"name": "hub", "enrolled": true},
 "members": [
   {"name": "hub", "node": "hub@10.0.0.1", "role": "orchestrator",
    "directory": "voter", "reported_seq": 9, "ms_since_report": 0},
   {"name": "laptop2", "node": "loom@laptop2.example.net",
    "role": "orchestrator", "directory": "none",
    "reported_seq": 7, "ms_since_report": 412000}],
 "last_refusal": null}
```

`state` is `ok`, `revoked` or `not_enrolled`. `reported_seq` is absent for a member
that has not reported. `ms_since_report` is the answering node's own elapsed time
and no clock value is exchanged. `last_refusal` is `null` or
`{"seq": 7, "step": "fork", "ours": "<hex>", "theirs": "<hex>"}`, where `ours` and
`theirs` appear only for a fork. If protocol-change/085 lands, its `NodeReport`
gains an optional `ledger` member holding `head` and `state`, and `ledger.status`
remains the detailed read.

### Configuration

```toml
[distribution]
node = "hub@10.0.0.1"
ca = "..."
certificate = "..."
key = "..."
cookie = "..."
ledger = "/home/me/.loom/distribution/ledger.log"
```

`ledger` is an absolute path, and the daemon reads the file at start. A document
with both `ledger` and `[[distribution.peers]]` is refused, and one with neither
is refused as today. With `ledger` set, `distribution.start` takes the loaded and
verified ledger, creates the table, and returns a `Membership` that resolves a peer
name against the live member set. The authority certificate named in the genesis
`authority` key MUST be the certificate in `ca`; a mismatch is `InvalidLedger`.
`docs/configuration.md` gains a row for the key, as `make doc-check` requires.

`distribution.Fault` gains `InvalidLedger` (the file does not verify, or does not
belong to this `ca`), `NotEnrolled` and `Revoked`. Each has an operator sentence
in `describe`. None carries a pin, key or cookie.

Until phase 2, `[executors.<name>]`, `[orchestrators.<name>]` and
`[directory] members` check their node against the ledger's member names
instead of `[[distribution.peers]]`. A node that was never in `ever` is refused as
today. A node in `ever` that is not active produces a warning and an inert row.

### The bundle

`loom-distribution-bundle/2` has the keys of `/1` with `peers` replaced by
`ledger`, an array of the complete ledger's lines in order. `decode` verifies the
chain against the bundle's `ca`, requires that a `member` entry for the bundle's
`name` carries the pin of the bundle's `certificate`, and refuses a bundle whose
role or node name differs from that entry. `install` writes the ledger file beside
the credentials and writes `ledger = ...` in place of the pin rows. `install`
prints the time of the last entry and states that the node trusts the snapshot
until it syncs. A `/1` bundle installs as before, and a `/2` bundle's tables are
merged by the same rules.

### Operator commands

`provision PLAN OUT` writes `ledger.log`, `/2` bundles and `system.json`. It writes
the authority certificate and the authority key, encrypted under a passphrase, to
`~/.loom/authority/<deployment id>` (mode 0700) unless `--drop-authority` is given,
in which case the ledger can never be extended. It reads the passphrase from a
terminal prompt or `--passphrase-file`, and prints neither. The encryption is
PBKDF2-HMAC-SHA256 with at least 600,000 iterations and a random salt, and
AES-256-GCM, both from OTP `crypto`.

| Command | Effect |
|---|---|
| `enroll NAME --node N --role R [--directory D] [--host H] [--port P] [--links A,B] [--out DIR] [--wait S]` | Validates the fold, mints a certificate for `N`, signs and appends a `member` entry, hands it to the daemon, writes `NAME.loombundle` (`/2`), and prints confirmations after at most `S` seconds (default 10). Until phase 3 it refuses a `--directory` other than `none`. |
| `revoke NAME [--force] [--wait S]` | Checks that the member owns no sessions or scopes, and that the link graph stays connected; signs and appends a `revoke`; prints confirmations. From phase 3 it also checks that the voter count stays within protocol-change/083's bounds. `--force` skips the checks. |
| `renew NAME` | Mints a new certificate for an existing member, signs a `member` entry with the new pin, and writes a new bundle. The node installs the bundle and restarts. Connections that exist stay up, because a pin is checked only at handshake; until the restart, the node's new handshakes are refused. |
| `log [--json]` | Prints the entries with their identities, the last refusal if there is one, and the members' reported heads when a daemon answers. |
| `import FILE` | Client-side. Reads a ledger file and feeds its lines to the local daemon's `ledger.append` in pages of 64. It adds no second way for a node to adopt entries. |

`enroll` and `revoke` take a lock on the operator's ledger copy and ask the daemon
for its head before they sign. If the daemon is ahead, they pull the missing
entries with `ledger.entries` and verify them first. They refuse if the daemon holds
an entry at a sequence number the operator's copy has, with a different identity.
They hand the entry to a daemon with `ledger.append` on the control socket they are
given (`--addr`, as other `loom` commands), and when no daemon is reachable they
write the entry to the operator's copy and tell the operator to run `import` on a
member's machine.

There is no command that resets a node after a fork. The design note documents the
procedure: stop the daemon, truncate the ledger file to the lines before the fork
point, start it, and let it sync.

### Phase 3: the directory

A deployment has two member lists. The ledger's lists every trusted node with its
pin. Khepri's lists the Ra voters and learners, a subset of the servers that
replicate the session directory. The ledger owns the first, Ra follows it, and a
trust change never waits for a quorum. Storing the ledger in Khepri would make it
wait, because a majority loss would stop the entries that restore trust.

When a member daemon has a `ledger`, `[directory] members` is derived from the
members whose `directory` is not `none`, and a document with both is refused.
Before phase 3 there is one voter list, the configured `members`, and `enroll`
refuses a `directory` other than `none`, so the ledger is never a second source.

A reconciler runs on the Ra leader only; `ra:members` names the leader, and a node
that is not the leader does nothing. It compares the derived voters and learners
with Ra's membership and issues one change at a time: a missing `voter` is added with
membership `promotable` (as in 083), a missing `learner` is added with membership
`non_voter`, and a Ra member that the ledger does not name is removed with
`ra:remove_member`. It recomputes the difference after each change and after each
leader change. The learner form relies on Ra 3.2.0's `non_voter` membership, which
is excluded from the quorum count and never promoted; it is verified through
Khepri's read paths in phase 0.

The order between the lists is fixed. An enroll puts the pin in the tables first,
and the Ra add follows. A revoke cuts the pin and disconnects at once, and the Ra
removal follows. Until `ra:remove_member` commits, the revoked voter is still in
Ra's configuration and still counts toward the quorum: with three voters, the two
that remain must both be up to commit the removal. After a majority loss, enrolling
a replacement restores trust, because the entry spreads without a quorum, but Ra
cannot add the replacement without a majority of the old configuration. Recovering
the directory then needs a Ra forced reconfiguration, which the ledger does not
perform. Protocol-change/083's rule that every `[orchestrators.<name>]` node on a
member daemon is a member continues to hold.

## Interfaces that move

| Interface | Before | After |
|---|---|---|
| `[distribution]` | `node`, `ca`, `certificate`, `key`, `cookie`, `listen_port`, `[[peers]]` | adds `ledger`, exclusive with `[[peers]]` |
| Options file text | Pins in the verify state | Static: unchanged. Ledger: verify state `live`, no pin |
| `verify/4` | State is the pin list | State is a pin list or `live`; `live` reads the `protected` table `loom_dist_pins` |
| `distribution.start` and `Membership` | Fixed, finite, immutable | Takes an optional loaded ledger; `Membership` resolves against the live member set |
| `distribution.Fault` | Seven constructors | Adds `InvalidLedger`, `NotEnrolled`, `Revoked` |
| Bundle | `loom-distribution-bundle/1` | Adds `/2`; `/1` still installs |
| Node-name atoms | Created once at start from the configured list | Also created when a verified `member` entry is applied, at most 256 |
| `net_kernel:allow/1` | Called once | Called per enrolled name; never reduced |
| Node vocabulary | `HostMessage`, `OwnerMessage`, orchestrator `Message` | Adds `loom_ledger` `Message` (`Head`, `Pull`); the others and `protocol.version` unchanged |
| Control protocol, Part 1.6 | | Adds owner-only `ledger.append`, `ledger.entries` and `ledger.status`, and the refusal `ledger_invalid` |
| Operator commands | `init`, `provision`, `show`, `install`, `options` | Adds `enroll`, `revoke`, `renew`, `log`, `import`; `provision` writes a ledger |
| Reference checks (phase 2, 3) | Against `[[distribution.peers]]` | Against ledger members; `[directory] members` derived in phase 3 |

No existing wire message, durable table or helper frame changes.

## What it costs

- A signing key on the operator's machine, which the design's one-shot
  `provision` did not have. Its loss ends membership changes until `provision`
  runs again, and its theft together with the passphrase lets a thief enroll a
  node every member accepts, with the same recovery. The operator's machine is
  often an enrolled laptop, and if it is lost the key goes with it and the response
  is `provision`, not `revoke`. Rotation costs what reprovisioning costs until a
  later change makes TLS pin-rooted.
- Membership changes are eventual. Between an append and its confirmation a
  stale node trusts a revoked member. A node isolated from every peer that has the
  tail, or fed an old prefix by its only source, cannot tell it is stale; a signed
  chain proves genuineness and not freshness. A revoke is stronger the sooner
  `revoke` prints every member as confirmed, and `import` is the path for a node
  nothing can reach.
- A revoke is not remediation. A pinned node already holds full Erlang
  privileges, and the disconnect is by claimed name, which the verify callback does
  not bind to the certificate. Binding it would mean changing `inet_tls_dist`,
  which owns the TLS socket.
- With the Khepri directory, the ledger's trust list and Ra's voter list are
  separate lists with a fixed order between them. Until the Ra removal commits, a
  revoked voter still counts toward the quorum. After a majority loss, trust can be
  restored by enrolling a replacement, and the directory cannot, without a Ra forced
  reconfiguration that the ledger does not perform.
- One more process on every distribution node, one more durable file, and a new
  closed vocabulary that becomes part of the "upgrade both ends together" rule.
- Two modes, static and ledger, until static mode is retired.
- Every existing deployment is reprovisioned once. A converter is not part of this
  proposal; see the design note.
- A test matrix with partitions. Phase 1 adds property tests over the pure fold
  (replay equals incremental apply, any prefix of a valid log is valid, a flipped
  bit or swapped pair is refused, equal logs give equal tables) and a model like
  those under `protocol/models`: no node applies two entries at one sequence
  number, the table is a function of the applied prefix, and a revoke reaches every
  node of a connected link graph, with a mutation for each.
- Small Erlang additions in the existing distribution and PKI FFI modules: a
  table row read in `verify/4` and a publish function, ECDSA sign and verify with
  the domain prefix, node atom creation, a `monitor_nodes` subscription and a
  disconnect if `gleam_erlang` exposes neither. Each is confined to an
  `internal/ffi_*` module with the reason no pure alternative exists.

## Phasing

0. A spike for the facts this proposal could not read from the tree: the verify
   callback reading a live table in a real handshake, the pin-less options file
   passing the boot check, the allow list as documented, and a `non_voter` member
   through Khepri.
1. The ledger, live pins, `provision`, `enroll`, `revoke`, `renew`, `log`, `import`,
   bundle `/2`, anti-entropy and the three control commands.
2. Derived `[executors]` and `[orchestrators]` rows, the revoke checks, and the
   head in `deployment.status`.
3. The directory alone: the Ra leader's reconciler, the `directory` standing,
   `[directory] members` derived from the ledger, and `enroll` accepting a
   `--directory` other than `none`.

Not built by this proposal: pin-rooted TLS and a `rekey` entry (a later note),
retiring static mode, cookie rotation, a signed checkpoint that compacts the log, a
threshold of signers, a signed heartbeat that bounds staleness, binding a
connection to its pin, and a converter for deployments provisioned before the
ledger.
