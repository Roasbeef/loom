# Sessions in one daemon

**Status: implemented on an unmerged branch; acceptance remains
incomplete.** The default entrypoint now runs one managed daemon, with no
legacy client/server compatibility path. [Client](client.md) describes the
current startup and protocol and labels the historical `f019322` baseline
separately. Focused tests below establish specific boundaries, not a completed
multi-session release gate.

The reader is an implementer tracing ownership from terminal startup to
session shutdown. [The design note](../design-notes/single-daemon.md)
records the alternatives and detailed failure analysis.

## Implemented assembly boundary

### Durable domain metadata

The catalogue also stores each session's domain mapping. `workspace_private`
preserves the owner's canonical workspace aggregate; `session_only` assigns
fresh memory and index paths for that session. The record captures the selected
maintenance configuration reference at creation, including an explicit no-config choice.
Opening sessions in a different order cannot replace it. Listing, restoring,
or isolating this metadata does not open conversation, memory, index, or
configuration files.

That reference does not replace each session's runtime configuration. A session
can select different providers and tools while retaining the same owner-private
domain paths; shared maintenance uses the domain's own configuration binding.

Only saved registrations appear in paged domain source enumeration. Reserved
registrations remain excluded before the page limit, so maintenance cannot
create their missing databases by opening them. Owner-authorized isolation
requires no retained runtime slot and copies no old aggregate files. See
[sharing scope](multiplayer.md#sharing-scope) for its transcript caveat. Runtime
resource admission consumes this mapping through `serve.build_domain` and
`serve.assemble_in_domain`; metadata persistence alone would not establish
that integration.

### Shared domain resources

The manager owns one history coordinator and optional maintenance cadence per
admitted domain. It captures the immutable domain record before preparing the
host, publishes cleanup before starting effects, and passes the original shared
history capability to each session. Session commit forwarders notify that owner
with the committing session's ID. History checks the current domain source list
before returning ranked results or reading an exact entry; stored index locators do not
authorize reads.

The domain book has the same capacity as the session book. Preparing, quiescing,
closing, and blocked domains remain counted, so repeatedly opening distinct
session-only domains cannot grow an unbounded retained map. Sessions waiting for
domain preparation occupy their own session slots. Listing and restoring saved
metadata still start no domain resources.

Closing one session leaves its shared domain available to other resident
sessions. Its original normal custody witness triggers a clean-close maintenance
notification. After the last dependency retires, the manager quiesces current
and coalesced maintenance, then cancels the domain host. Ordered cleanup retires
maintenance before shared history. Only the original normal domain witness
releases its reservation; failed cleanup retains capacity.

While daemon admission remains open, an explicit session open can revive a
quiescing domain before cancellation starts. It resumes maintenance and
replaces the domain's settle subject. A late reply to the withdrawn fence
cannot settle a later close, even if the worker decided that reply before
processing resume. Shutdown and blocked cleanup never permit revival.

The control `status` response reports `domain_capacity`, `domain_occupied`, and
`domain_blocked` separately from session counts. A `Saved` session can therefore
coexist with a retained closing domain. Normal daemon shutdown waits for both
books to empty.
A later explicit admission creates a fresh domain owner and may run another
cursor-based maintenance pass. The catalogue remains the source of its paths,
configuration, and authorized source IDs.

The real SQLite assembly test opens two sessions under one original history
owner, closes one while the other retains that owner, and joins the owner during
daemon shutdown. Restart restores only metadata; an explicit open creates a new
history owner. Separate public-custody tests cover blocked cleanup and cancellation
of domain preparation with two waiting sessions. The precise cross-sender
DOWN-before-result ordering is source-reviewed rather than deterministically
scheduled by those tests.

A joined cadence test also holds the initial pass while two sessions close.
The accepted coalesced pass still runs, and the original history and maintenance
owners remain alive while it is held. Releasing that final pass permits normal
domain retirement and releases domain capacity.

### Instance resources

`client/serve.Instance` groups one session's database runtime, gateway,
broker, helper pool and composition services. The managed entrypoint passes
the manager's existing custodian and published domain capabilities to
`serve.assemble_in_domain`. Assembly binds no listener and mints no daemon
token; the daemon root owns those resources once for all sessions.

`open_instance`, `close_instance`, and `Booted` remain internal host/test
adapters. In particular, the old `close_instance` returns no drain verdict.
The manager does not use that return as permission to release a reservation:
its owned path waits for the original custody witness.

Session services and writer subscriptions use reclaimable Weft reference
addresses. A replacement service binds the same address; a hint sent while
it is absent is lost without failing the durable commit. Each instance owns
its namespace and retires it on close.

`client/serve_test` opens two instances in one VM and completes a turn on
one after closing the other. It also measures ten fresh SQLite session
open/execute/close cycles with real helpers and no warmed atom growth.
These checks establish the reusable assembly boundary, not daemon recovery.
The separate `owned_assembly_test` exercises builder death during assembly,
failed effect cleanup, runtime drain before lease release, and fatal child
behavior. The retained custodian owns published cleanup even when the builder
can no longer report a result.

Each assembly now creates a random writer-owner identity. Closing SQLite
deletes the lease row, so the next open can reuse fence one; reusing the
owner too could restore authority to a still-open, expired connection.
A real-SQLite regression retains such a connection across takeover,
close and reopen, then proves it cannot renew or delete the current lease.
The saved session identity remains unchanged across these incarnations.

SQLite close also retains its first result. If lease deletion is blocked,
it returns an error through the binding's busy-safe path; later closes
return that same error rather than claiming the reservation can be freed.
This storage result is a prerequisite for the assembly's typed close,
not a replacement for external-effect drain proof.

The runtime's internal `api.open_published` hook publishes its root and
direct drain witness before the writer or any recovered driver starts.
The callback acknowledges custody or refuses startup. It runs once per
root, not on ordinary writer/driver restarts. Tests cover paused recovery,
refusal and session-owner death with a surviving Weft scope. Serving assembly
uses this hook to publish runtime shutdown before writer startup and recovery.
It shuts down the runtime tree without releasing storage early; the custodian
retires storage only after the effect cleanup sequence succeeds.

## Catalogue and ownership components

`storage/catalogue` implements durable creation reservations and saved-file
metadata. Its bounded pages carry a revision, and its unique identity, path
and request-key constraints reject conflicting registration. Reopening and
listing the catalogue never opens the conversation paths. The production
queries are generated from named SQL through parrot/sqlc; the schema is
embedded from the same checked-in SQL file used for generation.

Creation retries retrieve the original reservation by request key before
minting an identity or path. `session.ensure_reserved_id` persists that exact
identity and refuses a conflicting file. Workspace defaults are durable
catalogue mappings, validated against the selected registration's workspace.
Reading or changing a default never opens its conversation.

Durable recovery fixtures reopen the catalogue after a saved reservation and
after database identity publication but before catalogue confirmation. Listing
does not initialize the runtime. Retrying the creation key preserves the exact
session ID, path and domain, and a held cleanup witness prevents a second
builder from taking writer custody. These controlled builder and registry
failures do not constitute a whole-VM crash sweep.

`client/daemon/manager` serializes catalogue access and bounds live instances,
including instances whose cleanup is stopping or blocked. Creation explicitly
admits a reserved record; ordinary open refuses one. The registry confirms
the record only after assembly reports success. Its outer
`client/daemon/lifetime` owns one transitive registry witness, so completed
incarnations do not accumulate in a daemon-wide ownership ledger.

`client/internal/instance_host` prepares a parked builder and keeps it alive
after assembly returns. The registry creates and monitors its Weft custody
scope before releasing assembly. Creating that scope from a short-lived
opening job would close the session when the job exits, so preparation
belongs to the long-lived registry.

`client/internal/instance_owner` retains ordered cleanup capabilities after
builder death. A real-SQLite test holds a drain callback past the close
report deadline and verifies that another writer is still refused. Only
after drain and connection retirement can the same session reopen. Failed
cleanup remains blocked. The default `client/daemon/main` now connects these
components to serving assembly and the authenticated v2 listener. Separate
real-SQLite and native-TUI fixtures exercise that integration; the combined
failure, resource-load, and live multiplayer drive remains an acceptance gate.

Helper retirement now uses the accepted
[shutdown frame](../../protocol-change/014-helper-shutdown-witness.md).
The broker retains the port until native exit and then joins the original
BEAM owner. Its pool inventories a parked helper before starting its native
process and retains both idle and borrowed helpers until retirement is
confirmed. Serving assembly also prepares MCP clients, publishes their cleanup
capability, and only then starts them. A failed or unconfirmed native cleanup
retains custody rather than being treated as a successful session close.
Focused helper and MCP checks do not establish the entire release drive.

## One process across workspaces

One `loomd` process runs one BEAM VM and hosts the user's active sessions
across workspaces. Each session has one gateway, one supervision tree,
and one conversation database. Several terminals can attach to the same
session, and one terminal can switch between sessions without stopping
the work it leaves behind. See [multiplayer](multiplayer.md) for the
authority and ordering of those attachments.

The default state directory stores daemon metadata and saved sessions.
It does not partition projects into separate servers. A separately
configured state directory is an explicit isolated deployment, not a
normal consequence of changing the terminal's working directory.

```mermaid
flowchart TD
    T1[Terminal A] --> L[One authenticated listener]
    T2[Terminal B] --> L
    L --> M[Session manager]
    M --> C[(Durable catalogue)]
    M --> O[Session ownership and drain custody]
    O --> A[Session A supervision tree]
    O --> B[Session B supervision tree]
    L --> GA[Gateway A]
    L --> GB[Gateway B]
    GA --> A
    GB --> B
    A --> DA[(Database A)]
    B --> DB[(Database B)]
```

## Ownership

The daemon owns discovery, authentication, the listener, the catalogue,
and admission against global resource limits. The session manager handles
small lifecycle messages. It does not run database opens, snapshot scans,
or external-process drains inside its request handler.

A session owner retains its runtime, gateway, effect services, and cleanup
handles. Cleanup custody must survive that owner's death. A replacement
owner cannot execute until the predecessor's effects have drained and its
writer authority has been released. A supervisor detecting a dead process
is not evidence that its external effects have stopped.

The session remains the unit of execution authority and cancellation.
Generated programs run in kernel-enforced sandboxes outside the harness
VM. They receive session-specific broker capabilities, never the daemon
credential. Daemon files and other registered conversation databases must
be protected even when workspaces overlap.

## Discovery is not execution

The catalogue assigns saved sessions stable identities and records their
database paths, workspaces, configuration references, and lifecycle state.
Listing or previewing a session reads metadata without opening its runtime:
the current runtime open path can resume durable unfinished operations.

Concurrent requests to open the same session converge on one owner.
Opening unrelated sessions may proceed concurrently under admission
limits. Every open gets a fresh incarnation and writer-owner identity so
late callbacks cannot affect a replacement runtime.

Closing a client detaches one connection. Stopping a session drains its
work and preserves its database. Shutting down the daemon drains every
session. A caller's timeout stops its wait, not the server's cleanup, and
cannot release a capacity reservation whose work may still be alive.

Stopping a session is not the same as aborting its operation. Runtime close
retires the tree and drains its effects at a durable commit boundary without
writing a cancelled or terminal operation state. An explicit later open can
therefore resume the admitted operation. For an interrupted provider request,
recovery records the unknown outcome before continuing; a second HTTP request
does not imply a second user admission. The client still must not resend a
mutation whose acknowledgement was lost. These are different responsibilities:
the runtime recovers durable intent, while the terminal preserves uncertainty
about whether its command was admitted.

After a whole-daemon restart, restore the catalogue and leave every
session closed. Open a session lazily when an authorized operator selects
it or explicitly requests an open. Catalogue listing and metadata preview
never open a session, run its schedules, or resume unfinished operations.
Automatic transport reconnect does not reopen a session across daemon
epochs; the client requires an explicit selection or open request.

Lazy opening uses the same admission, ownership, and cleanup checks as
any other open. Concurrent requests for one session share one opening
runtime. Once opened, the session uses its existing durable recovery
semantics, which can resume unfinished work. Sessions that were active
before the restart remain closed until requested.

## Client startup and routing

A terminal first discovers and authenticates the existing daemon. A failed
connection does not authorize replacement: the launcher must observe that
the recorded native process has departed. A short-lived launch lock
serializes that decision separately from the daemon's lifetime lock.
Discovery works while the live daemon holds its lifetime lock. A listener
accepting TCP is not ready; the authenticated protocol and daemon epoch
establish reuse.

The control API lists and manages sessions. Session sockets route to one
gateway and remain bound to that session and incarnation. The manager does
not forward each token, stream fragment, or conversation write. Catalogue
invalidation and conversation catch-up have separate revisions because
they describe different stores.

Selecting another session keeps the current view usable until the new
connection authenticates and supplies its initial snapshot. Each attempt
owns its inbox and deadline. Old messages and failed attempts cannot
change the adopted view. A replacement connection reconciles durable state
and never automatically resends a mutation with an unknown outcome. Current
terminal failure handling marks the connection disconnected; it does not
start an automatic reconnect loop. Internal tests and the live drive verify
recovery through explicit session selection, not automatic reconnection.

If the original control owner has retired, list, open and create reconnect
inside their managed action worker. The frame loop remains responsive during
the handshake. Each replacement belongs to that worker and closes when it
finishes or is cancelled; the model retains the original route rather than
adopting a new background control owner. Subsequent explicit actions may pay
another handshake, but an uncertain creation is not automatically resent.

### Implemented shared endpoint boundary

`host/endpoint` owns one bounded, private `daemon.endpoint` beneath the
canonical state root. Its version-one schema names gateway protocol two.
A `Starting` record carries the OS PID, platform birth marker, and diagnostic
start time. `Ready` adds the actual loopback host/port and daemon epoch.
The record contains no workspace, session database, bearer credential, or
redirectable token path. The fixed credential path is `owner.token`.

Automatic startup acquires `launch.lock`, checks the existing native fence,
starts a paused wrapper, observes its birth identity, and writes `Starting`
before releasing the child. The launcher then releases `launch.lock` before
waiting. The child reacquires that lock to adopt its own reservation; holding
it while waiting for the child would deadlock startup. Direct foreground
startup writes the same reservation before catalogue or session acquisition.
`daemon.lock` remains the root's separate lifetime lock.

The daemon requests port zero and publishes the actual selected port only
after retaining its original listener owner. The launcher reads the private
owner token and requires an authenticated `/v2/control` hello with the exact
published epoch. `tui/bootstrap.resolve_daemon` returns that terminal-owned
control connection without creating or opening a session. The standard
conversation UI and `/sessions` selector now use that connection. Selecting
a saved session requests its open, then adopts the candidate only after its
authenticated initial cut validates.

A still-live PID/birth pair or an identity-observation error never permits
replacement after a failed probe. Malformed endpoint records fail closed.
A missing endpoint beside an existing `catalogue.db` requires the operator
to establish that the previous VM and native children have exited and to
recover the endpoint; startup neither deletes the catalogue nor guesses that
the old owner is dead. Normal root shutdown retains the record until the
original VM departs. In particular, killing a BEAM root can release its kernel
lock while its VM remains alive, so the native fence still refuses startup.

The focused tests cover the real paused-child handoff, authentication and
epoch refusal, two workspaces reusing one native PID without opening sessions,
and root KILL followed by a failed probe after lifetime-lock release. These
establish bootstrap behavior, not the complete interactive multiplayer drive.

## Containment and bounds

Session supervision contains ordinary actor failures. An OOM, native
library fault, or VM crash can affect every session; one VM is not an
OS-level resource boundary between sessions. Per-session worker VMs are
not part of this implementation.

Long-lived hosting requires reclaimable runtime addresses: dynamically
allocated atoms survive session close. Audit node-global state before
reusing session assembly. Install VM-wide handlers once, carry workspace
and environment as session values, and coordinate shared search/memory
stores explicitly instead of deriving them from daemon startup cwd.

Admission must bound active sessions, helper reservations, inbound frames,
queued work, snapshots, and slow-client output. A blocked session must not
prevent another session from accepting a prompt or the control API from
reporting status. Limits need measured defaults and executable tests.

## Verification required before release

`make e2e-multiplayer` runs the terminal, authority, persisted-restart,
approved-effect and fault-containment fixtures. `make soak-daemon` runs the
real-daemon lifecycle soak; it is distinct from the simulated `make soak`.
These fixtures retain bounded execution and remain in the ordinary client
suite. The [six mutation checks](../review/single-daemon-mutation-gates.md)
show which deliberately broken protections the focused tests rejected.

The default is implemented. Published `00076858` passed Linux, jailed E2E
and the 200-seed CI job, but macOS failed the paired-latency assertion.
An earlier head passed both platforms; that result does not make this head
green. Exact heads, retained samples and local results are recorded in
[the handoff](../next.md#verified-results-and-their-limits). Those results do
not validate an unadopted dependency or establish the entire joined drive.

The shipped identity-recovery fixture also starts a native terminal while
creation remains on its original opening operation. After VM death, selection
must end with a control-loss failure without adopting a conversation. The
terminal's session, channel, captured snapshot and records must retain their
pre-crash values. Explicit same-key recovery waits for the original lease to
expire; a fresh terminal then validates the original session under the
replacement daemon's epoch and current runtime incarnation. This observes
pending selection, not a particular outstanding frame or an ambiguous prompt.

Live owner-authenticated terminals have verified rendering and submission
without another keypress, recovery through explicit selection, and switching
to a shared session. `daemon_fault_containment_test` verifies peer progress
while another session retains a blocked provider and writer lease.
`daemon_schedule_residency_test` closes a real attachment before an overdue
one-shot fires. After stop and original-root retirement, it adds another
schedule through normal storage, restarts the daemon, and proves listing keeps
the session inactive. Explicit open fires the second occurrence without
replaying the first prompt or replacing its fired cell. Recurring cursor
arithmetic remains separate scanner-test coverage.

The original resource soak found 192 additional SQLite file descriptors after
16 measured cycles, despite stable atoms and helper ownership. The evaluation
binding held 68 descriptors across 16 cycles in 14.20 seconds, but is not an
adopted dependency. [ADR-002](../adr/002-sqlite-binding.md) records the pending
retirement correction and its adoption boundary. The final dependency state
still needs the resource and release gates; a passing soak assertion alone
does not establish stable descriptors or resident memory.

Filesystem acceptance has two distinct gaps. Application filesystem dispatch
still bypasses the jailed planner. The separate native PrivateScratch work
under protocol 017 remains restricted and unverified. No multiplayer test or
planner codec result establishes confinement across overlapping workspaces.

Two terminals starting in different workspaces must converge on one daemon.
Two sessions must execute concurrently with separate databases and no
cross-delivery. Two clients on one session must observe the same durable
event order while a third client uses another session.

The drive must also cover concurrent open, failed replacement, client
detach, owner death, listener restart, blocked drain, and whole-daemon
restart. Repeated open/close cycles must stabilize atom and resource counts.
The fixtures above cover specific cases; the final release evidence must name
the cases exercised rather than claim every fault permutation from their count.

For the restart case, save two active sessions, restart the daemon, and
list them. Assert that both records survive while no session runtime,
provider call, tool execution, or schedule starts. Then select one session
from two clients concurrently: exactly one runtime opens, both clients
attach to it, and the other session remains closed. A denied open request
must leave both sessions closed when neither was already resident.

## Implemented runtime prerequisite

The runtime uses Weft v0.4.4 reference addresses for strand drivers and for
the writer, registry and drain ledger. It allocates no dynamic process names.
The two strand factories are unnamed and publish their current handles in the
registry. Runtime close and root death reclaim service routing; the retained
direct drain-ledger subject still governs whether the writer lease can be
released.

The runtime tests execute and close 50 sessions after warming the VM, assert
zero atom growth, and check that old roots, drivers, namespaces and addresses
are gone. A blocked-provider test kills the root and observes namespace death
before close; close must still wait for the provider to drain before another
writer can acquire the database. These tests establish runtime prerequisites,
not the daemon or multiplayer experience above. The assembly boundary also
uses reference addresses for client services. Cleanup custody across builder
death is implemented by the owned assembly path described above; a lost
transitive retirement proof remains a deliberate recovery-blocked boundary.
