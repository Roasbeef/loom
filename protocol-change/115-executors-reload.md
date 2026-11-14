# protocol-change/115: `executors.reload`, so a running daemon learns a new untrusted executor

**Status**: ACCEPTED 2026-11-13, under the delegation of `docs/execution.md`
section 7, after one independent adversarial review ("Review and disposition"
below). Not built.
**Affects**: the client control protocol (one new owner-only command,
`executors.reload`, and one new refusal code, `reload_invalid`), one new process
in the daemon, which owns the untrusted executor rows and their links, and one
answer of the untrusted link (a request for a session the link holds no binding
for is answered `NoPlane`). The daemon also creates the vm home at its start.
`loom.toml` does not change: the command reads the tables of
[109](109-untrusted-executors.md) as they are. The link's wire, the remote node
vocabulary of [078](078-distributed-runtime.md) and its `version`, the
catalogue schema and every Part 1 interface are unchanged.
**Raised by**: the microVM tier. `loom vm up --link untrusted` writes a guest's
row into `loom.toml`, and a daemon that is already running never reads it
(`docs/design-notes/microvm-untrusted-link.md`, section 4(a) and slice 2).
**Builds on**: 109 (the untrusted link and its two tables),
[086](086-membership-ledger.md) (the precedent for an owner-only command that
changes rows in a running daemon, `ledger.append`).
**Issue**: loom #85.

## Problem

The daemon reads `[executor_link]` and the `[executors.<name>]` rows once, at
its start, and starts one link process for each untrusted row then. Nothing
reads them again. A guest made while the daemon runs is therefore unreachable
until the daemon restarts, and `loom vm up` handles that today by stopping a
daemon that holds no session and by telling the user to stop one that does.

That is the last reason a first `loom --vm` run interrupts anything. It also
means a link that died is never started again, because links are started in one
place and that place runs once.

## What was considered

**The daemon watches `loom.toml` (rejected).** A poll loop, a debounce, and a
hand edit taking effect at a moment the user did not choose. The only
authentication would be the file's permissions.

**A command that carries the row, `executors.link {name, address, pin}`
(rejected).** The row would then exist in the file and in the daemon's memory,
and the two could disagree until a restart settled it in the file's favour.

**A command that makes the daemon reread its own file (accepted).** The file
stays the one record. The caller writes it first and then asks the daemon to
read it, so a daemon that is not running, or that predates the command, still
reaches the same state at its next start.

**A reload of one named row, `{"name": ...}` (rejected).** It would bound what
one call can change to one row. A session opened on `~/.loom` or on the home
directory can write `loom.toml`, so a model there can rewrite another guest's
`address` and `pin`, and with a whole-file reload that edit takes effect at the
next reload where today it waits for a restart. Naming a row does not remove
that: the edit still takes effect at the next start, and a daemon is started
often. It would also leave a dead link of any other row down. We keep the
whole-file reload and make every change it applies visible instead: the reply
lists it, the clients print it, and the daemon logs it ("The clients").

**A general configuration reload (rejected).** Most tables have consumers that
cannot be replaced under running sessions: `[distribution]`, the trusted rows,
pools, the listeners. An untrusted row's only consumer is its link, which can
be started and stopped without touching a session on any other executor. The
command is named for what it reloads and does nothing else.

## Decision

### The command

`executors.reload` takes `{}`. It is owner-only (a member is refused
`forbidden`), needs no epoch, and is a mutation: a daemon that is draining
refuses it as it refuses any mutation.

The daemon reads the configuration file it started from and decodes the whole
document with the decoder its start uses. The call is refused with
`reload_invalid`, a reason as the `message`, and no change, when:

- the file is one a start would refuse;
- `[executor_link]` is not one the daemon may apply ("The link key and the
  masks");
- an untrusted row has the name of an executor the ledger enrols, which the
  written row would shadow;
- the file holds more than 512 untrusted rows, or the daemon has seen 1,024
  distinct untrusted names since it started. Each name becomes an atom, for the
  link's registered name, and names now arrive over the daemon's life.

A daemon that was started with no configuration file answers `not_found`.

From a file that passes, the daemon takes every row whose `trust` is
`"untrusted"` and brings its links to match:

| The row | What the daemon does | `change` |
|---|---|---|
| is new | starts a link | `started` |
| has the address and pin the running link was started with, and the link is alive | nothing | `unchanged` |
| has them, and the link is dead | starts a link | `restarted` |
| differs in address or pin | stops the link and starts one under the same name | `restarted` |
| is gone from the file | stops the link | `stopped` |
| could not be brought to match within the call's bound | leaves the row as it was before the call | `failed` |

Trusted rows and every other table are neither applied nor compared.

The reply's event is `executors.reload`:

```json
{"v":2,"reply_to":7,"event":"executors.reload","body":{"executors":[{"name":"old-9a01c2","change":"stopped"},{"name":"proj-464e8b","change":"started"},{"name":"review-pod","change":"unchanged"}]}}
```

`executors` lists every untrusted row the file holds or the daemon held, sorted
by name, at most 512 entries. The reply has no booleans. `started`, `restarted`
and `unchanged` mean the daemon holds the row and a link for it. They do not
mean the executor answers: a link dials on its first request.

The daemon logs every entry that is not `unchanged` at warning level, with the
old and the new address and pin, and the reason of a `failed` one.

### What a new link means for a session

A link started in place of another holds no bindings, because a binding is
minted by an attach and lives in the link's process. Two cases follow.

**The executor behind the row is the same one.** This is a link that died and
was started again. The executor still holds the session's plane, so its host
would never answer `NoPlane`, the surface would never attach again, and every
callback of the session (an escalation, a fact, a background job's wake) would
be refused for a binding the new link does not hold. So the link itself
answers a `run` or a `start` for a session it holds no binding for with
`NoPlane`. The surface then attaches again, by the path
[078](078-distributed-runtime.md)'s re-attach addendum added, and the executor
rebinds the plane it already has. Until a session's next call, its callbacks
are refused; a background job that finishes in that window wakes nothing.

**The executor behind the row was replaced.** A row's address changes when the
guest restarted on another port, and the guest's host then answers `NoPlane`
on its own account. A row's pin changes only when the guest was removed and
made again, and a new guest holds no scope record for the old sessions: their
calls are refused until they are opened again, which is what removing a guest
means.

The daemon never stops a link whose row is unchanged and whose process is
alive. A session keeps the placement it was created with, and a reload changes
which executors a new session may be placed on.

A request in flight on an executor whose row was removed behaves as a request
on an executor that died: it is retried until the operator aborts it. A send
to a link's name while no process holds it is dropped and does not raise in
the sender, because the surface addresses the link as a name on a node; the
surface then waits for a link to hold the name again.

### Who owns the rows

One process, `client/daemon/untrusted_links`, holds the untrusted rows and the
pid of each row's link. It starts each link, unlinks it and monitors it, so a
link's death neither takes the owner with it nor goes unnoticed, and the next
reload starts the link again. Before it starts a link it stops whatever
process holds the link's name, so a link left by an earlier owner is replaced
and never refused.

The read of the file happens inside that process, so two reloads cannot apply
their reads out of order. `loom vm` writes the file atomically and under its
own lock, so a read never sees half a write.

A stop is a kill and a wait for the name to be free. A link start does not
dial. The whole reconcile is bounded at three seconds, inside the five the
client waits for a reply; a row not reached by then is `failed`, stays as it
was, and is tried again by the next reload.

The roster that placement, `deployment.status` and session creation read is
computed at each use from the trusted rows the daemon started with and this
process's rows. In ledger mode both go through the derivation the daemon uses
today, so a row the ledger derives is unaffected. In static mode a pool that
names a row the file no longer holds fails the decode, so that file is refused
and the link stays; in ledger mode a pool skips a name it cannot find, as it
does today.

### The link key and the masks

A jailed process must never read the orchestrator's link key: with it, the
process can connect to a guest as the orchestrator. The key is protected by a
mask over the vm home, and a mask is built only for a path that exists when the
jail's policy is built. A session keeps the policy it booted with. So on a
daemon that started before the first `loom vm up` on the machine, every
session already open can read the vm home once it appears. That is true today,
with or without this command, and for the distribution link's cookie as well.

Two rules remove it:

1. The daemon creates `$HOME/.loom/vm` and `<state root>/vm`, mode 0700, at
   its start and before it admits a session. Every jail it builds then masks
   them, whenever the first guest is made.
2. `executors.reload` applies an `[executor_link]` table only when it equals
   the table the daemon started with, or when the daemon started with none and
   each of the table's files resolves to a path under one of those two
   directories. Anything else refuses the whole call with `reload_invalid`,
   and the table takes effect at the next start.

A vm home moved with `LOOM_VM_HOME` to somewhere else is therefore not applied
by reload. Rotating the link's credentials is a restart, as it is today.

### The clients

`loom vm up`, `loom vm ensure` and `loom vm rm` write `loom.toml` as they do
today and then, for a guest on the untrusted link, send `executors.reload` to
the daemon of the default state directory when one is running and the file
changed or the daemon does not list the guest. They no longer stop that daemon.
`ensure` on a guest that already serves and that the daemon already lists sends
nothing.

They read the reply and print every entry that is not `unchanged`, whichever
guest it names, so a row that changed without the user's doing is seen. Their
own guest's `failed`, and any refusal, are reported with the advice `up` gives
today.

A daemon that predates the command answers `bad_request`, the code of an
unsupported command. An empty body cannot be malformed, so the clients read
`bad_request` as "predates the command" and do what they do today: stop a
daemon that holds no session, and name the command that stops one that does.

A daemon started from another configuration file cannot be found by these
commands, which is unchanged.

## What it costs

One command, one refusal code, one process, the roster becoming a read through
that process where it was a value fixed at start, one new answer in the link,
and a directory made at every daemon start in homes that never run a guest.
About 800 lines of product code and as many of tests.

An edit to an untrusted row by anything that can write `loom.toml` now takes
effect at the next reload, where it waited for a restart. The reply, the
clients' output and the daemon's log are what make it visible.

After a link is replaced, a session that makes no call has its callbacks
refused until it does. A reconciler that attaches idle sessions again was not
built: it is more machinery on the owner port for a window that a dead link
already has today, without an end.

`vm_spec.daemon_step` and the code that stops an idle daemon stay, for a
daemon that predates the command and for a guest on the distribution link.
They are removed with the distribution path (slice 5 of the design note).

## Tests

- First, before any other code, in the `untrusted_end_to_end_test` rig: attach,
  kill the link, start one under the same name, run a call that escalates, and
  assert the owner is asked. It fails without the link's `NoPlane` answer and
  passes with it.
- `client/executor_reload_test`: the plan from a held set and a desired set is
  the table above, for every pair of states a row can be in, by a property
  over generated row sets; the `[executor_link]` rule; the reply's codec.
- `client/daemon/untrusted_links_test`: a row added, changed, removed and
  killed, each observed through the link's registered name, and a name held by
  a stranger's process.
- `client/daemon_executors_reload_test`: an owner is answered, a member is
  refused `forbidden`, and a file a start would refuse changes nothing.
- `client/remote/untrusted_reload_test`: with one executor attached, the file
  gains a second, `executors.reload` over a real control socket answers
  `started` for it and `unchanged` for the first, the first link's pid is the
  same, and a call on the second executor returns.
- A jail built by a daemon that started before any guest existed cannot read a
  file made afterwards under the vm home.
- `daemon_shipped_microvm_test`: with the daemon still running, a second guest
  is brought up and serves a session, and the daemon was never restarted.

## Review and disposition

One independent, read-only adversarial review, 2026-11-13, against the code at
the head that lands the opt-in link. Each finding was checked in the code
before it was taken.

| Finding | Disposition |
|---|---|
| A link started in place of a dead one holds no bindings, and a live executor never answers `NoPlane`, so callbacks are refused until the session is reopened (`untrusted_link.admitted`) | Taken: the link answers `NoPlane` for a session it holds no binding for. The draft's claim that the 078 path covered it was wrong. |
| The draft gated applying `[executor_link]` on a mask that does not exist for a jail built before the vm home did (`workspace_policy.protecting` filters on `exists`) | Taken: the two rules above. The exposure predates this proposal. |
| A model that can write `loom.toml` gets its edit applied at the next reload | Taken as visibility: the reply, the clients and the log. A named-row reload was considered and rejected above. |
| Link ownership, a name left by an earlier owner, and the call's time bound were unstated | Taken. |
| A trusted row reported `needs_restart` had no reader, and `reason` belongs in the log | Cut. |
| Rotating credentials by reload | Cut: a changed `[executor_link]` refuses the call. |
| The 1,024-name cap as a per-row failure | Made a whole-call refusal. |
| The ledger roster must go through the ledger's derivation, and a written name must not shadow an enrolled one | Taken. |
| An old daemon's answer is `bad_request`, not a distinct code | Taken. |
| An idle session's callbacks are refused until its next call after a link is replaced | Accepted as a cost, stated above. |
