# Membership ledger: adding and removing nodes without reprovisioning

Status: **proposed, 2026-10-11. Design only; nothing here is built.** The
owner chose the shape to explore (an operator-signed, append-only log of
membership entries that every node replays into a live pin table); this note
argues it, compares it with the alternatives, and records where it is weak.
The wire and file formats it would add are drafted in
[protocol-change/086](../../protocol-change/086-membership-ledger.md). It
builds on the distributed runtime of PR #923
([the architecture page](../architecture/distributed.md),
[protocol-change/078](../../protocol-change/078-distributed-runtime.md)) and is
meant to work with and without the Khepri directory of PR #934
(protocol-change/083). It is written for the remote subagents work
([protocol-change/084](../../protocol-change/084-remote-subagents.md)), where
laptops that come and go are pinned peers of a hub.

## 1. The question

`loom distribution provision` mints one authority, one ECDSA P-256 certificate
per node and one cookie. It writes one bundle per node holding that node's key,
the cookie, and a pin (the SHA-256 of the leaf certificate plus the node name)
for each node it trusts, and then drops the authority key. Each node renders
the pins into its TLS options file and accepts a distribution connection only
from a pinned leaf. That is a sound boundary and a short list of moving parts,
and it has one cost. The pin list is fixed when the bundle is installed, so
adding a node, removing one, or renewing a certificate means provisioning
again and reinstalling every bundle.

For two always-on machines that is tolerable. For an operator whose laptops are
spawners for remote subagents it is not: each new laptop, each lost laptop and
each certificate renewal touches every other machine in the deployment. The
remote subagents note already records the revocation procedure that results: an
operator who loses a laptop bundle "removes the laptop's pin from
`[[distribution.peers]]` on every node and restarts them".

This note asks how a node can be added or removed with one operator action, no
reinstall of the other nodes and no restart, and what that costs.

## 2. The decisions in brief

1. **A membership ledger.** An append-only log of entries signed by one
   operator key. Each entry carries a sequence number and the hash of the
   previous entry. Two entry kinds do the work: `member` (enroll, amend or renew
   a node) and `revoke`. A third, `genesis`, starts the log.
2. **Every node replays the log into a pin table** that the TLS verify function
   reads at handshake time. Changes take effect without a restart. Applying a
   `revoke` also disconnects the node, because TLS checks the pin only at
   handshake.
3. **No consensus.** One signer means one writer, so the order of entries is
   fixed by the signer. A node accepts an entry from any peer when the
   signature and the chain check, so a peer is not trusted to relay honestly.
   Two different signed entries at one sequence number are a fork. A node
   refuses the second, stops extending its log and reports the fork.
4. **Nodes learn the log by anti-entropy over the existing pinned
   distribution.** Each node stores the log in a local file. When two nodes
   connect they exchange their head (sequence number and entry hash), and the
   one that is behind pulls. The operator appends through any one reachable
   daemon and the entry spreads. Learning is eventual, so `enroll` and `revoke`
   report which nodes have confirmed the new head.
5. **One mechanism for every deployment.** The ledger is not stored in Khepri.
   When a deployment has a Khepri directory, the Ra voter set follows the
   ledger: a reconciler adds a voter or a learner when a `member` entry names
   one and removes it when a `revoke` does.
6. **The operator key is kept.** `provision` stops dropping the authority key
   and keeps it encrypted on the operator's machine. It is one key with two
   uses: it signs node certificates and it signs ledger entries. Its loss or
   theft becomes the main risk of the design, which section 5 states in full.
7. **Reprovision once to migrate.** A deployment created before the ledger is
   provisioned again by the new version, which emits the genesis entry and the
   first members. A converter is not worth its second code path.

The remainder of the note gives the reasons, the mechanism, the holes found
while arguing it, and the phases.

## 3. What exists today

The facts the design leans on, each of which is in the tree:

- The pins live in the options file. `tls_options` renders the verify function
  together with the pin list as its state, `ssl_dist_optfile` carries that text
  to the VM at boot, and `distribution.start` refuses a VM whose loaded
  options differ from what the configuration generates. Changing a pin
  therefore changes a file that is read once, at boot.
- The verify function (`verify/4` in `client_distribution_ffi.erl`) keeps every
  PKIX failure and, for the leaf, requires a matching pin and a node-name
  subject alternative name equal to that pin's node name.
- `net_kernel:allow/1` is called once with the configured peers, between one
  and 32. Peer names become atoms once, at start, from that finite list, and
  `distribution.peer` looks a name up in it. OTP documents that the allow list
  only grows: a node cannot be removed from it, and changing it does not
  disconnect a connected node. The allow list cannot carry a revocation.
- The trust graph is not a full mesh. An orchestrator pins the executors it
  uses and the other orchestrators. An executor pins only the orchestrators
  that use it. Two executors do not pin each other unless Khepri makes both
  members. A design that replaced this with "every enrolled node trusts every
  other" would widen the blast radius of a lost laptop from the executors it
  uses to all of them, so the ledger carries the edges (section 4).
- The cookie is one value for the deployment, written to
  `$HOME/.erlang.cookie` by `install`. It is a second check behind TLS.
- Node certificates last 1825 days and the authority certificate 3650 days.
  Renewal is rare, which keeps the renewal story below short.
- `[executors.<name>]`, `[orchestrators.<name>]` and `[directory] members`
  each check their node against the `[[distribution.peers]]` list when the
  configuration is read.
- Every node already runs Loom's own verify code, so the live table needs no
  new hook in OTP. It needs the verify function to read a table instead of a
  list in its own state.

## 4. The ledger

### 4.1 Entries

The ledger is a file of lines. Each line is the URL-safe base64 of an entry
body, a dot, and the URL-safe base64 of a signature over that body. The body
is UTF-8 JSON written by the operator's tool with a fixed key order and no
whitespace. Verifiers do not re-serialize it. They check the signature over
the exact bytes they received and then parse those bytes, which removes the
question of canonical JSON.

The identity of an entry is the SHA-256 of its body bytes. The signature is not
part of the identity, so two signatures over one body name the same entry. Every
body carries the format marker, `seq`, and `prev`, the identity of the previous
entry. Entry 0 is `genesis` and its `prev` is 32 zero bytes. A body after
genesis is one of two kinds.

```json
{"format":"loom-membership-ledger/1","seq":4,"prev":"9f2c...","time":"2026-10-11T18:02:11Z","kind":"member","name":"laptop2","node":"loom@laptop2.example.net","host":"laptop2.example.net","role":"orchestrator","directory":"none","links":["hub","devbox"],"pins":["3a7b..."]}
{"format":"loom-membership-ledger/1","seq":5,"prev":"c4e1...","time":"2026-10-11T19:40:02Z","kind":"revoke","name":"laptop2","pins":["3a7b..."],"reason":"laptop lost"}
```

A `member` entry is an upsert keyed by `name`, which is the plan name and the
bundle name. It sets the member's Erlang node name, host, optional listen port,
one `role` (`orchestrator` or `executor`, the roles of the existing plan), a
`directory` standing (`voter`, `learner` or `none`), the `links` that name the
other members it may connect to, and one or two `pins`. The first entry for a
name enrolls it. A later entry with the same pins amends its role or links. A
later entry with different pins renews it, and carrying two pins lets the old
and the new certificate both be accepted while the node switches, after which a
third entry drops the old one. A `revoke` removes a member and records the pins
it held, for the audit trail. Revoking a name that is not an active member is
invalid. Re-enrolling a revoked name is an ordinary `member` entry.

The owner's sketch had `Enroll {node, pin, roles}` and `Revoke {node, pin}`.
The refinement is that enroll, amend and renew are one entry kind, because they
differ only in how the new value compares with the old one and a second and
third kind would be three paths through one fold. `roles` became two fields,
`role` and `directory`, because they answer different questions: what the
daemon does, and whether it votes in the session directory.

`genesis` carries a random deployment id, the SHA-256 of the authority
certificate, and the creation time. The signing key is taken from that
certificate, which every node already holds as its trust root, so no new key
format is introduced and a node can check at install and at every boot that its
ledger and its CA file belong together. Signatures are ECDSA P-256 with SHA-256
over the bytes `"loom-membership-ledger/1" 0x00 body`, so a signature made for
the ledger cannot be replayed as any other use of the same key. The `time`
field is the operator's clock and is informational; no rule reads it.

### 4.2 The fold

The state of the ledger is a deterministic fold over its entries: the active
members by name, plus the set of every name ever enrolled. The fold rejects an
entry that would break an invariant, and the operator's tool runs the same fold
before it signs, so a rejection by a node means the signer was buggy or
compromised.

- Node names pass the grammar `distribution.check_node_name` already applies,
  and are unique among active members. A pin appears under at most one active
  member.
- A `links` entry names an active member. A `revoke` removes the edges to the
  removed member without a further entry.
- At most 64 members are active, at most 256 distinct names are ever enrolled,
  and the file holds at most 10,000 entries of at most 4 KiB. The first two
  bound the atoms the node creates (section 6.4); the third bounds replay.
  A deployment that reaches 10,000 entries has made thousands of changes and
  can run `provision` again, which is the compaction.

The pin table of node `N` is derived from the fold. A pin of member `M` is in
`N`'s table when `M` is not `N` and the two are linked, where `N` and `M` are
linked when either lists the other in `links`, or when both have a `directory`
standing other than `none`, because Ra needs every member able to reach every
other. The table maps each pin to the node name it must present, which is what
the verify function compares with the certificate's subject alternative name.
Deriving edges from `links` keeps today's least-privilege graph: a laptop is
enrolled with `--links hub,devbox` and no other executor will accept it.

If `N`'s own name is not an active member, `N` does not start distribution and
says it is not enrolled. If `N` applies a `revoke` naming itself, it stops
dialing, disconnects its peers and reports that it was revoked. That is how a
revoked node that was offline learns its fate when a peer it can still reach
tells it.

## 5. The authority key

Today no key remains after `provision` that could issue a certificate or sign a
membership change, which is a real property: a stolen operator machine yields
nothing about the deployment. The ledger gives that property up, because a
membership change needs a signer. The cost is stated here rather than
discovered later.

**One key, two uses.** The authority key that signs node certificates also
signs ledger entries. Nodes already hold the authority certificate, so the
public key needs no new distribution, and the operator has one secret to
protect. Two keys would be two secrets in the same place, since `enroll` needs
both together: one to mint the leaf and one to sign the entry. The domain
prefix on every ledger signature separates the two uses cryptographically.
Open question 1 records the alternative.

**Custody.** `provision` writes the authority key encrypted under a passphrase
to a private directory on the operator's machine (`~/.loom/authority` by
default), with the operator's copy of the ledger beside it. The key is read
only by `enroll`, `revoke` and `provision`, never by a daemon, and no node
holds it. The operator can run the deployment with the operator's machine off:
membership changes are the only thing that needs the key. `provision
--drop-authority` keeps today's behavior for an operator who prefers no
persistent signing key; the deployment then cannot change its membership,
which is today's rule exactly.

**Loss.** If the key and every backup are lost, the deployment keeps running and
cannot change. Recovery is `provision` again, which costs what every change
costs today. The operator's copy of the ledger is recoverable from any node.

**Theft.** A thief who has the key file and the passphrase can sign an `enroll`
for a node the thief controls, with a certificate the thief issues, and every
node accepts it. Nodes cannot tell the difference, because the signature is the
only evidence of operator intent. Recovery is `provision` again with a new
authority, followed by reinstalling every bundle. Two observations bound this.
A thief with the file but not the passphrase has an offline guessing problem.
And the new risk is on the operator's machine, which already holds the bundles
and the cookie in the clear while they are being delivered.

**Rotation.** In the first phases rotating the key costs what it costs today:
a new authority means new certificates, so every node gets a new bundle. The
reason is not the ledger. The authority certificate is the TLS trust root in
every node's options file, and a node reads that file once. Section 14.2
describes how pin-rooted TLS removes the reason, after which a `rekey` entry
signed by the old key could name the new one. That is later work, and the
phases do not depend on it.

## 6. How nodes learn the log

### 6.1 Anti-entropy over the pinned connection

Every daemon with a ledger runs one process, registered as `loom_ledger`, that
owns the file and the pin table and speaks a small closed vocabulary to its
peers on other nodes. The messages hold bytes and integers and no atom or
function derived from peer input, and the receiver decodes the entry lines with
total decoders even though the peer is pinned, because entries are durable and
are relayed.

```gleam
pub type Message {
  /// What the sender holds. Sent when a connection comes up and on a timer.
  Head(seq: Int, id: BitArray)
  /// Entries after `after`, at most `limit` (clamped to 1 through 64).
  Pull(after: Int, limit: Int, reply: Subject(Entries))
  /// Entries the receiver is missing, offered unasked.
  Offer(lines: List(BitArray))
}
```

The rules are these.

1. When two nodes connect, each sends the other its `Head`. A node that
   receives a `Head` with a higher sequence number pulls the missing entries
   and applies them in order. A node that receives a `Head` with a lower
   number offers the next page. So either side converges the pair, and a node
   that dials a stale node does not need the stale node to ask.
2. A node applies an entry only after it checks the signature, the chain
   (`seq` is the head plus one and `prev` is the head's identity) and the fold
   (section 4.2), and it makes the entry durable before it publishes the new
   table.
3. After it applies entries, a node sends its new `Head` to every connected
   peer except the one it learned from. Connected peers also exchange heads
   every 60 seconds, which repairs a lost message.
4. Equal sequence numbers with different identities are a fork (section 6.3).

An orchestrator also keeps, for each member it is linked to, the last head that
member reported. Members that have not reported the current head are pending,
and the orchestrator dials them, with a retry interval that starts at 5 seconds
and doubles to a ceiling of 5 minutes. Only orchestrators dial, as in
protocol-change/078. An executor learns when an orchestrator connects, which is
the same event that lets the orchestrator see the executor's head. The
reported heads are what `enroll`, `revoke` and `log` print.

The messages travel on connections the deployment already makes, in both
directions of a link, with no new port. A deployment with one orchestrator and
one executor exchanges two 40-byte heads per minute.

### 6.2 How the operator appends

`enroll` and `revoke` run on the operator's machine. They unlock the key, read
the operator's copy of the ledger, compute the entry, sign it and append it
locally under a file lock. They then hand the entry to one daemon through an
owner-only control command (`ledger.append`) on that daemon's control socket,
and wait up to a deadline for confirmations. The daemon verifies the entry like
any other, so the command adds no trust in the caller beyond the ordinary owner
check. If no daemon is reachable, the operator copies the ledger file to any
member and runs `loom distribution import` there, which verifies and adopts a
longer valid chain. That path needs no network machinery and is the fallback
for a node that nothing else can reach (section 9.2).

Before it signs, the tool asks the daemon it is about to use for its head. If
the daemon's head is ahead of the operator's copy, the tool pulls the missing
entries first, and if the daemon holds an entry the operator's copy does not
contain at a sequence number the operator's copy already has, the tool refuses.
This is the only way a single operator forks the log by accident: restoring the
key and an old copy of the ledger from a backup on a new machine. The check
costs one round trip and turns that case into a refusal.

### 6.3 Forks

A fork needs two signatures over different bodies at one sequence number. A
single operator tool that locks its own file does not produce one. A fork means
the key signed in two places, through a backup restored at an old head or
through theft. A node that holds an entry at sequence `n` and receives a
different valid entry at `n` keeps what it has, refuses the other, writes both
identities to a marker file, stops applying further entries, and reports the
fork in `log`, in its logs and through the control protocol. Entries that build
on the other branch fail the chain check on that node anyway. The operator
resolves a fork by choosing the branch that is right and running a local
`loom distribution reset --to SEQ` on each node that took the other branch,
which truncates its log to before the fork point; the node then syncs again.
If the fork came from theft, the answer is section 5. Detecting a fork is cheap,
and resolving one is manual because the cause is not a routine event.

### 6.4 The pin table and node names

The verify function reads the table from one row of an ETS table owned by the
ledger process. The row holds the whole immutable table and is replaced by a
single insert, so a handshake sees the old table or the new one and never a
mixture. The options file holds no pins in ledger mode; its verify state is the
atom that selects the table. Enrolling or revoking therefore leaves the options
file unchanged, which keeps the boot check that the loaded file equals the
generated one. If the ledger process is down, the table is gone and the
verify function refuses every handshake. A restart reloads the file and
recreates the table, so the failure mode is a short refusal and never an
acceptance.

Peer names become atoms when the ledger applies a `member` entry, and not from
the network. Only a name in an entry whose signature verified, that passed the
grammar, and that is within the 256-name bound is turned into an atom. Today's
rule, "peer names become atoms once, from the finite configuration", relaxes
to "from the finite, signed ledger", with the bound as the finite part.

`net_kernel:allow/1` is called with each enrolled name and never shrinks. A
revoked name stays allowed. That is harmless: the allow list is a check on the
claimed node name, the pin is the check on the certificate, and a revoked
certificate has no pin. Removal is enforced by the table and by disconnecting.

### 6.5 Disconnecting on revoke

Applying a `revoke` publishes the new table and then disconnects the node
by name. A handshake that read the old table just before the swap can finish
just after it, so the sweep runs once more after the longest a handshake may
take. `distribution.start` sets `net_setuptime` to 5 seconds, so the second
sweep runs at 6. After that every connection that exists was accepted under the
new table.

This disconnects by claimed name, which has a limit already recorded on the
architecture page: the verify function does not bind the certificate's name to
the name the peer claims in the handshake. A revoked holder that connected under
another pinned node's name is not disconnected by this sweep. New handshakes
with the revoked certificate are refused, and the connection ends when it
drops. Section 8 says what that means for a compromised member.

## 7. Storing the ledger in Khepri instead

With the Khepri directory of #934 present, the log could be stored in the
Khepri tree and replicated by Ra, and the ledger would need no anti-entropy of
its own. The question is whether a second mechanism earns its place.

What Khepri would add is a commit acknowledgement: a write returns when a
majority of voters have it, and a consistent read says whether this copy is
current. Gossip cannot say the second. A node that is cut off, or whose only
peer withholds entries, cannot tell that its table is stale (section 9.4).

What it costs, ordered by weight:

1. **Circularity.** Ra members connect over pinned distribution. A new voter
   must be in a node's pin table before the node will talk to it, and the pin
   table would come from the log in the store those nodes are trying to
   reach. The bootstrap must come from a file anyway, and every voter needs a
   way to learn pins when the store is down. Once a file and a way to spread it
   exist, the store holds a copy of something already replicated.
2. **Not every deployment has Khepri.** The directory exists for deployments
   with orchestrators and executors in a voter set of three or more. A hub with
   one executor has none, and laptops joining such a deployment are the case this
   note is for.
3. **Quorum loss blocks revocation.** A write needs a majority. A lost
   laptop is revoked when the operator may be least able to bring back a
   majority. With gossip the operator appends at any one reachable daemon.
4. **The store is not signed.** Any member with write access to the store could
   write a membership change. The signed chain makes every copy verifiable
   without trusting the writer or the relay.
5. **Two mechanisms.** The house rule is to take one of two mechanisms with the
   same properties, and these do not have the same properties, which is the
   argument of items 1 to 4.

The recommendation is one mechanism, anti-entropy, for every deployment, with
the Khepri voter set following the ledger (section 11.3). What the deployment
gives up is the majority-committed acknowledgement and the freshness read.
Both are partly replaced by the reported heads, which tell the operator which
nodes have the entry and name those that do not. Neither is replaced for a
node that cannot be reached, and section 9.4 says what that leaves open.

## 8. Signatures and the trust envelope

Every pinned node already holds the full privileges of an Erlang peer on every
node it can connect to. A compromised member can run any function on any other
member, read any session, and use any provider key. Signing the ledger does
nothing about that, and this note claims no more. An operator signature does
not protect a deployment from a member that is already compromised, and
revoking a compromised member does not undo what it did while it was trusted.

The signatures protect four other things, and these are the reasons to have
them:

- **A joining node checks what it downloads.** The bundle's snapshot and
  anything pulled later are verified against a key the node already holds, so a
  node on a hostile network cannot be fed a table.
- **Relays need no trust.** An entry is accepted from any peer, including a
  node about to be revoked, a node reached through an intermediary, or a file
  carried on a USB stick. The chain stops a relay from reordering or omitting
  an entry in the middle. It does not stop it from withholding the tail
  (section 9.4).
- **Outside audit.** The ledger is a public, verifiable history of who was
  enrolled with which pin and when, readable by anyone with the authority
  certificate, without access to any running node.
- **Narrower privileges later.** If member privileges are ever narrowed (a
  port that accepts only typed messages, or an executor that no longer exposes
  `rpc`), what remains is the question of who may become a member. The ledger
  answers that question with one signing key, and the answer then matters.

A revoke is therefore a statement that a node will not be accepted again. It is
not remediation. An operator who revokes a lost laptop stops its next
connection. An operator who believes an attacker ran code on a member rebuilds
what the attacker could reach, which no membership mechanism changes.

## 9. Revocation edge cases

### 9.1 A node that is offline

A node that is off during a `revoke` applies it when it next connects to a node
that has it, because the head exchange pulls the missing entries. Until then it
trusts the revoked member, which matters only if that member can reach it. The
window is the node's time offline plus the seconds until it first syncs. A
laptop behind NAT is not dialable by the revoked node, and a laptop dials out
when it wakes, so the realistic exposure is small.

### 9.2 A node whose only reachable peer is the revoked node

An executor serves orchestrators and is dialed only by them. If the only
orchestrator linked to the executor is the revoked one, the executor never hears
of the revoke and keeps accepting that orchestrator's certificate. How likely:
low, because the revoked orchestrator must be the only orchestrator linked to
that executor, so the executor has no honest user left. How bad: the holder of
the revoked credentials can still use that executor, which the operator probably
retires along with the orchestrator.

The tool prevents the likely cases before they occur. At append time it checks
that the link graph after the entry is connected and that every executor has at
least one other orchestrator that is not the subject of the revoke, and it warns
or refuses (with `--force`) when that is not so. For the remainder, `revoke`
prints each member that has not confirmed the head, and the operator carries the
ledger to that node with `loom distribution import`. That is a documented
assumption in place of machinery. A mechanism to push a revoke to a node that no
live orchestrator dials would be a new way to reach an executor that today
nothing reaches.

### 9.3 A revoked node that is online and connected

The sweep in section 6.5 disconnects it. Its new handshakes are refused
immediately. Sessions on a revoked executor fail through the same path as an
executor that is down: the orchestrator sees the connection drop, and the
attach-or-run machinery of protocol-change/078 handles it. Sessions owned by a
revoked orchestrator are not deleted. They become unreachable until the node is
enrolled again, and no failover exists today.

### 9.4 Stale tables and rollback

A signed chain proves an entry is genuine, not that the node has the newest
one. A peer that is a node's only source can serve an old, valid prefix of the
log and withhold the rest. A bundle kept in a drawer for a month holds an old
snapshot. In both cases the node trusts members the operator has since revoked,
until it syncs from an honest, up-to-date peer.

How likely: a node would need to be isolated from every peer that has the tail,
or fed by one adversarial peer, while the revoked member can also reach it. How
bad: the same as a missed revoke for that node. The mitigations are modest and
cheap. A node syncs from every peer it connects to, not only the first. `install`
prints the age of the snapshot in the bundle and says that the node will trust
the snapshot until it syncs. The reported heads show the operator which nodes
are behind. The design does not add signed heartbeats, because that would make
the operator's machine a dependency of steady state to bound a rare staleness.
Khepri's consistent read would bound it, and section 7 explains why this is
not worth a second mechanism.

### 9.5 A sleeping node is not a revoked node

Enrollment is a fact about identity. Presence is a connection. A laptop that
sleeps for a week is still enrolled when it wakes, and no entry is written. The
operator writes entries only when a machine is added, removed, or renewed.

## 10. What is in a new node's bundle

`enroll` writes a bundle with a new marker, `loom-distribution-bundle/2`. It
holds the node's name, role, node name, host, listen port, bundle directory and
the `[executors.<name>]` or `[workspaces.<name>]` rows of the `/1` bundle, the
authority certificate, the node's certificate and key, the cookie, and in
place of the `peers` list, the complete ledger as its lines. The ledger is the
snapshot; with a few dozen members it is a few kilobytes. The head is the last
line. `install` verifies the chain against the authority certificate, checks
that the node's own certificate pin appears in a `member` entry for its name,
writes the ledger file, and writes `ledger = ...` in place of the pin rows in
`[distribution]`. A `/1` bundle installs as today.

The order matters. `enroll` appends the entry and hands it to a daemon before
the new machine is online. Existing nodes learn the new pin from the ledger
first. The new node starts, dials a node it is linked to, which accepts its
pin, and exchanges heads. A node that has not yet learned the entry refuses the
new node, and the new node retries with backoff until its peer's table updates.
A new node needs no other node to be reachable except through that first link.

**The cookie.** The cookie is delivered in the bundle and not by the ledger.
Removing a node leaves the cookie in the hands of whoever holds the node's old
bundle. The cookie protects a deployment from a connection that gets past TLS,
and a revoked node has no pin, so it does not get past TLS. Rotating the cookie
would need the ledger to carry a secret, which means encrypting it to each
member, or a second channel for delivery. That is a new mechanism to protect a
second line behind a first that holds. The recommendation is to leave the
cookie out of the ledger, to keep it shared, and to treat a change of cookie as
`provision` again until a demonstrated need appears.

## 11. Removal is more than a pin

A `revoke` entry removes a pin from every table. Four other things follow, and
who does each matters because the ledger itself has no veto and no side effects:
an entry is applied by every node by the same pure fold.

### 11.1 Sessions

The operator's tool, not the ledger, checks first. Before it signs a `revoke`
for an orchestrator it asks the deployment which sessions that orchestrator
owns, and for an executor which scopes it holds, and it refuses while there
are any unless `--force`. The ledger does not veto because nothing in a log
fold can see sessions, and a veto at apply time would give two nodes different
tables from the same log. The refusal is a safety check on the operator. The
revoke is reversible, since enrolling the same node again restores its pins,
and it destroys no session.

### 11.2 Executor pools

A pool row that names a revoked executor behaves as an executor that is down.
A first open moves to the next candidate when the connection fails, and a
session whose scope record names the executor waits, both as the architecture
page describes. At boot a row naming a node that was never enrolled is an error,
as today, because it is a typo. A row naming a node that was enrolled and later
revoked is a warning, since the operator is entitled to start the daemon after a
revoke and edit the file at leisure.

### 11.3 Khepri and Ra

A node with a `directory` standing is a member of the Ra cluster. A reconciler
on each directory member compares the ledger's `voter` and `learner` members with
`ra:members` and issues the difference to the leader: it adds a member that is
missing (as `promotable`, the form #934 already uses, for a voter), and removes a
member that is no longer in the ledger. Two members racing issue the same
idempotent command, and `cluster_change_not_permitted` while a change is in
flight is retried. #934 has no command to remove a Khepri member and needs
none for this: the `revoke` is the removal command.

The order is deliberate. The pin table changes first, so the revoked node stops
being reachable at once, which Ra sees as a down member. The Ra change follows.
Removing a voter needs a majority of the current configuration to commit, so a
revoke that arrives when the voters are already below a majority cannot remove
the node until the majority returns. That is the situation Raft always has, and
it is not made worse. The tool checks the voter count (three to seven in
protocol-change/083) before it signs a change that touches a voter.

**Non-voting members.** Ra supports them. Reading the Ra 3.2.0 source in
#934's build tree: the membership type is `voter | promotable | non_voter | unknown`,
a member is added with a map `#{id, membership, uid}` to `ra:add_member`, and
the quorum calculation counts only voters, so a non-voter never counts toward
the majority. `promotable` is the form #934's join uses; Ra promotes it to a voter
once its log has caught up, and promotion is implemented only for it. A
`non_voter` is never promoted, and Ra refuses to transfer leadership to it. The
Ra source also warns that a member announced to the cluster and slow to
start reduces availability by raising the quorum count, which is the cost of
enrolling a laptop that sleeps as a voter. What I did not find is a test of a
permanent `non_voter` through Khepri's own read paths, because #934's spike
measured only `promotable`. That is a phase-0 check (section 16).

So the `directory` standing decides the Ra role: `voter` is added as
`promotable` and becomes a voter, `learner` is added as `non_voter` and stays
one, and `none` is not a Ra member. An always-on executor or orchestrator is a
voter. A laptop is `none` by default, and `learner` when its owner wants local
reads of the directory. `enroll` warns when it is asked to make an
orchestrator a voter. The rule in protocol-change/083, that every
`[orchestrators.<name>]` node on a member daemon is itself a member, is the
reason a laptop would be a learner and not simply absent: if a member daemon
names the laptop as an orchestrator, the laptop must be a member of some kind.

## 12. The `[orchestrators]` and `[executors]` tables

Adding a node should be one write. The recommendation is a split by who knows
what.

The ledger carries facts that must be the same on every node: the member's
name, Erlang node, host, listen port, role, directory standing and links. Local
configuration carries what is one daemon's own policy: the control address a
client uses to reach an orchestrator (the asking daemon's knowledge, as
`orchestrators.gleam` explains), an executor's declared platform, enforcement and
toolchains (the operator's claims for one orchestrator's pools), and which
executors sit in which pool.

Phase 2 derives default rows. An orchestrator treats every enrolled executor it
is linked to as an `[executors.<name>]` row with no declarations, and every
enrolled orchestrator it is linked to as an `[orchestrators.<name>]` row, using
the ledger's name. Where it is a Khepri member the orchestrator rows are only
those that are members, to satisfy the rule in section 11.3. An explicit row with
the same name overrides the derived one and adds the address, declarations and
pool membership. So a new executor can be named in `sessions.create` the moment
it is enrolled, and a pool still needs one config edit because a pool is
policy. Phase 1 changes only where the existing rows are validated: against the
ledger's names instead of `[[distribution.peers]]`.

## 13. Commands

`loom distribution` (`dist`, and `loomd distribution`) gains these. Existing
commands keep their meaning in static mode.

| Command | What it does |
|---|---|
| `provision PLAN OUT` | Writes the genesis entry and one `member` entry per plan node, one `/2` bundle each, and `system.json`. Keeps the authority key encrypted in the operator directory and the operator's copy of the ledger there. `--drop-authority` restores the one-shot behavior. |
| `enroll NAME --node N --role R [--directory D] [--links A,B] [--out DIR]` | Mints the node's certificate under the kept authority, signs a `member` entry, appends it locally, hands it to a daemon, writes `NAME.loombundle`, and prints which nodes have confirmed the head. |
| `revoke NAME [--force] [--wait SECONDS]` | Checks sessions and the link graph (sections 9.2, 11.1), signs a `revoke`, appends it, and prints confirmations. |
| `renew NAME` | Mints a new certificate for an existing member and signs a `member` entry carrying both pins; `renew NAME --finish` drops the old pin. |
| `log [--json]` | Prints the entries with their identities and, when a daemon is reachable, each member's last reported head. |
| `import FILE` | On any node: verifies a ledger file and adopts it if it extends the local chain. A file that disagrees with the local chain at some sequence number is refused as a fork. |
| `reset --to SEQ` | On a node: truncates the local ledger after a fork (section 6.3). |

The daemon gains two owner-only control commands in the client protocol,
`ledger.append` (a list of entry lines) and `ledger.status` (the local head,
state, member list and each member's reported head). If protocol-change/085
lands, its `deployment.status` report carries the head too and
`ledger.status` stays the detailed read.

## 14. Migration

### 14.1 From today's bundles

A deployment provisioned before the ledger has no authority key (it was dropped),
so a converter that builds the genesis from `system.json` and the existing pins
cannot sign anything with the key nodes already trust. It would have to
introduce a new authority, and nodes' trust roots would need the new
certificate. So the converter and a reprovision both touch every node once and
restart it once. The converter saves the regeneration of keys and the cookie and
costs a second install path, a new file format and a test matrix for a state that
exists only during migration.

The recommendation is a one-time reprovision. `provision` from the new version
emits the genesis, the first members and `/2` bundles. The distributed runtime
was merged recently, so the number of live deployments is small, and the
owner's deployment can be reprovisioned. If a deployment that is not the owner's exists
by the time phase 1 lands, a converter becomes cheaper than asking its operator
to reprovision, and its design is the small `adopt` file: a signed genesis and
member entries, the new authority certificate to append to the node's trust
roots, and nothing secret.

Static mode remains. A daemon with `[[distribution.peers]]` and no `ledger` key
works as now, and the table refuses both together. Static mode is what the
tests and a hand-built two-node setup use. It is retired in phase 3, when
`provision` has emitted ledgers for long enough.

### 14.2 Pin-rooted TLS, later

Today the verify function requires the PKIX chain to a trust root and a pin.
Once the ledger holds the pins, the chain adds nothing: a pin of the exact
certificate is stronger than trust in any issuer. A later phase can accept the
two chain failures that mean "issuer unknown" (`unknown_ca` and
`selfsigned_peer`) when the pin and name match, and keep every other failure,
so expiry and key usage are still enforced. Then the authority certificate is no
longer a TLS trust root and only the ledger signs with it. Two things follow.
The authority key can be rotated with a `rekey` entry signed by the old key,
because no options file names the old one. And a node can generate its own key
and certificate and send the operator only the certificate, so the private key
never travels in a bundle. This needs a spike (does `ssl` accept a verify
function that resolves an unknown issuer without a CA file?), so it is phase 3.

## 15. Alternatives considered

**Reprovision, as today.** Correct, and the reference for what must keep
working. It fails the stated use: every change touches every node.

**CA trust plus a revocation list, or short-lived certificates.** Nodes would
trust any certificate chained to the authority with a node-name SAN, so adding
a node needs no change elsewhere. It solves admission, and does not solve
membership. Nodes still need a roster to know who to dial, which executors an
orchestrator may place work on, and who is a Ra voter, so a roster has to
exist, and the roster is the ledger. A revocation list needs a transport and
has the same freshness problem as the ledger. Short-lived certificates make
revocation "stop renewing", which takes effect when the certificate expires, and
need a renewal service that a sleeping laptop cannot reach on schedule. The
authority key would still be kept online, with a wider job.

**A live pin list pushed to each node by the operator.** The operator connects
to every node and sends the new list. It has no signatures, so a node cannot
distinguish a push from the operator from one from anyone with control access,
no chain, so no catch-up for a node that missed a push, and no history. It
requires the operator to reach every node at once, which is the original
problem for a laptop. It is the ledger without the part that makes it converge.

**The ledger stored in Khepri.** Section 7.

**The ledger spread by anti-entropy.** Chosen.

**A quorum of signers instead of one.** A threshold of operator keys would
protect against theft of one key. It adds a signing ceremony to every change of a
two-laptop deployment. Rejected until a deployment has more than one operator.

## 16. Phasing and cost

**Phase 0, a spike (a few days).** Check the things this note could not read from
the tree: that the verify function reads a live table during a real
`inet_tls` handshake, that a new pin is accepted and a removed pin refused without
a restart, that the pin-less options file passes the boot check, that
`net_kernel:allow/1` growth behaves as documented, whether the peer certificate of
an established connection can be read after the handshake (which would let the
sweep and the name check bind a connection to a pin), and that a `non_voter`
Ra member works through Khepri's own reads. The answers decide open questions 5
and 6 and the shape of phase 3.

**Phase 1, the ledger (the bulk of the work).** The pure module (entries, total
decoders, chain, fold, pin table; no I/O, so it is property-testable: replay
equals incremental apply, any prefix of a valid log is valid, a flipped bit or
a swapped pair is refused, two nodes that apply the same log have the same
table), the file store with atomic append and tail repair, the `loom_ledger`
process, anti-entropy, the live verify function and disconnect sweep, the bundle
`/2`, `provision`, `enroll`, `revoke`, `log`, `import`, `reset` and the two
control commands. The architecture page's existing provisioning modules are
about 2,700 lines of source in this tree; this phase is a comparable amount of
source and more tests, which I estimate at three to four weeks for one person
who knows the area. The Erlang additions are small: the table row read in the
verify function and a publish function in the existing distribution FFI, sign and
verify in the existing PKI FFI, the node-name atom creation, and a node-up
subscription and a disconnect if `gleam_erlang` exposes neither. Each goes in
an `internal/ffi_*` module with the reason no pure alternative exists, as the
FFI rule requires.

**Phase 2, configuration and status (about a week).** Derived
`[executors]` and `[orchestrators]` rows, the revoke checks (owned sessions, link
graph, voter count), the head in `deployment.status`, and the documentation of
the new keys.

**Phase 3, Khepri and renewal (two to three weeks).** The Ra reconciler and the
`directory` standing, `[directory] members` derived from the ledger, `renew`,
the spike-dependent pin-rooted TLS and `rekey`, and retiring static mode.

**What it costs the project.** One more process on every daemon that has
distribution. A second durable file per node. A signing key on the operator's
machine and the custody rules in section 5. A new closed vocabulary that
becomes part of what the architecture page lists as "both ends are upgraded
together". A rule that membership changes are eventual, which adds a column to
every status output. And a test matrix with partitions in it: I recommend a small
model like those under `protocol/models`, checking that no node applies two
entries at one sequence number, that the pin table is a function of the applied
prefix, and that a revoke reaches every node in a connected link graph, with a
mutation for each.

## 17. Open questions

Each has a recommendation.

1. **One key or two?** One authority key signs certificates and ledger entries.
   *Recommendation: one.* Two keys would sit in the same file for the same
   command and double the custody work without adding independent protection.
2. **Make TLS pin-rooted?** *Recommendation: yes, in phase 3, after the spike.*
   It makes key rotation cheap and lets nodes keep their private keys. It is not
   needed for phases 1 and 2, and a relaxation of the verify function belongs
   behind a measurement.
3. **Keep static `[[distribution.peers]]` alongside the ledger?** *Recommendation:
   keep it through phase 2, refuse both together, and retire it in phase 3.* A
   hand-built setup and the test fixtures need a mode with no signing key.
4. **How is the authority key stored?** *Recommendation: a passphrase-encrypted
   file in phase 1,* with the signing step behind a one-function seam so a
   keychain or hardware token can replace it. OTP `crypto` has PBKDF2 and AES-GCM.
   A hardware token is better and is not worth blocking phase 1 on.
5. **Should a revoke refuse while the node owns sessions?** *Recommendation: yes
   in the operator's tool, with `--force`, and never in the ledger.* The ledger
   cannot see sessions, and revoke is reversible.
6. **Can a connection be bound to its pin?** If the spike shows that the peer
   certificate is readable after the handshake, bind the claimed node name to
   the pin and disconnect on mismatch. That fixes the revoke sweep and the
   impersonation the architecture page notes. *Recommendation: do it if the spike
   shows it is a few lines; otherwise document the limit as section 6.5 does.*
7. **Compact the log?** *Recommendation: no.* The cap of 10,000 entries is far
   beyond one operator's changes, and `provision` is the compaction. A signed
   checkpoint entry adds a second way to start a chain.
8. **Rotate the cookie through the ledger?** *Recommendation: no* (section 10).
9. **Explicit `links`, or edges derived from roles?** *Recommendation: explicit,*
   because deriving them from roles silently lets any laptop attach to every
   executor, which today's pins do not.
10. **Converter or reprovision?** *Recommendation: reprovision,* revisited if a
    deployment other than the owner's exists when phase 1 lands.
11. **Does a laptop join the Khepri cluster?** *Recommendation: `none` by
    default, `learner` on request, `voter` only for always-on machines,* with
    `enroll` warning on the last. The default follows the owner's rule that a
    sleeping laptop must not count toward the majority.
12. **Where do `enroll` and `revoke` get the daemon to hand the entry to?**
    *Recommendation: the owner's control socket of any daemon they can reach,
    and `import` for any node nothing can reach.* The operator's machine need
    not run a daemon.
13. **Should a node refuse inbound connections until it has synced once after
    waking?** *Recommendation: no.* A laptop behind NAT is not dialable, it dials
    out and syncs within seconds, and the machinery would address a rare, cheap
    exposure with a new state machine.

## 18. Where this sits

This note is the design. The formats, the interfaces that move and the costs
are in [protocol-change/086](../../protocol-change/086-membership-ledger.md).
The architecture page's "Limits and deferred work" entry on one-shot
provisioning points here. The ledger is independent of the remote subagents
work, which it makes more pleasant to use, and it composes with the Khepri
directory without requiring it.
