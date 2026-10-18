# protocol-change/089: the parent's operator approves a remote child's request

**Status**: ACCEPTED 2026-10-17, as built in phase 3 of
[protocol-change/084](084-remote-subagents.md), slices S10 and S11. The owner
ruled on 2026-10-17 that box-to-laptop traffic is pushed, that a laptop
approval may grant only what is in the stored `wanted` list and inside the
spawner's `approval_ceiling` and may last once or for the session, and the
three defaults below.
**Affects**: the client control protocol (Part 1.6): the `escalation` record
gains two optional members, `placement` and `admitted`, and an `escalation_id`
that names an orchestrator; the orchestrator port's closed message type gains
`ChildEscalation` and `Resolve`; `loom.toml` gains
`[spawners.<name>.approval_ceiling]`; durable cells that are not Part 1
interfaces: the parent's `remote-escalation/` cells, the delegate session's
`delegate/outbox/escalation/` rows, and a new provenance for a remembered grant.
**Raised by**: [docs/design-notes/remote-subagents.md](../docs/design-notes/remote-subagents.md)
section 11, which left this as phase 3, and the owner's rulings above.
**Builds on**: protocol-change/084 (the port, the `ChildHost`, the box's outbox
and its drainer, S9), [007](007-escalation-carries-the-action.md) (the action
echo), [041](041-session-approval-dialog.md) (remembered permissions) and
[073](073-web-session-grants.md) (provenance and the Forget list).

## Problem

A child that runs on the box is refused by its sandbox exactly as a local child
is, and the refusal is a durable escalation record in the delegate session. In
phase 1 nobody is attached to a delegate session, so the call settles on the
refusal and the child works around it. The operator who started the child is on
the laptop and cannot see the question. The box's owner can attach to the
delegate session and answer, but the person who asked for the work is the one
who should be asked, and the box's owner may not be anyone who is watching.

Three things make this more than forwarding a record.

- The laptop's operator must not be able to widen the box's sandbox beyond what
  the box's owner allowed that spawner. A pinned peer is trusted as a peer, but
  an operator's mistaken click should not reach `/etc`.
- The two machines are connected only when the laptop's link keeper holds the
  connection, and the box does not dial. A question cannot depend on a request
  that the box makes and the laptop answers inline.
- An answer for the session must reach later calls of that parent's other
  children on the box, and no other session's calls.

## What was considered

### The laptop asks the box for its escalations (rejected)

Polling `escalations_get` over the port is the shape of the other box-to-laptop
reads. It makes the laptop dial the box on a timer for questions that are
usually absent, shows a question up to a poll late, and cannot know when to
stop. S9 settled that box-to-laptop traffic is pushed from an outbox over the
connection the laptop keeps, and a question is one more such row.

### Writing the record under the laptop's own `escalation/` prefix (rejected)

The terminal and the page already draw `escalation/` cells. But the session's
tool clearance scans that prefix on every call and consumes `Approved` records
whose scope matches the call being cleared. A record that belongs to another
machine must be unspendable here, so it lives under `remote-escalation/`, which
the clearance never reads, and the gateway and the cut learn the second prefix.

### Approving by sending the box the laptop's decision as an assertion (rejected)

A message that said "the operator approved" with no `expected_seq` would let a
stale card approve a question that had changed. `Resolve` carries the `seq` the
operator was shown and the echoed action and grants, and the box judges them
against its own record, as a local `approve` is.

### A decision the box applies without its own ceiling check (rejected)

The laptop has the list of grants the ceiling admits, because the box sent it,
and refuses a wider approval before it leaves the machine. That is for the
operator's benefit. The box checks again, because the ceiling is the box
owner's policy and the laptop's copy is the last thing it heard.

## Proposal

### Configuration

```toml
[spawners.laptop.approval_ceiling]
writable_roots = ["/srv/work"]
readable_roots = ["/usr/share"]
network = ["registry.npmjs.org:443"]    # or "any"
env = ["NPM_TOKEN"]
limits = { wall_s = 600 }
scratch = ["tmpfs"]
```

One key for each constructor of `broker/policy.Grant`. A missing table means no
ceiling, which is phase 1: the delegate session counts as unattended and no
decision from the spawner is accepted. A present table with no keys asks the
operator and admits nothing. A grant of `0` for a limit (unlimited) is never
admitted. `docs/configuration.md` has the table; the decoder is
`client/approval_ceiling`, and `admits` names every grant constructor so that a
new kind of grant is a compile error until its bound is decided.

### Parking

For a delegate session, `escalate.Config.interactive` is true when a client is
attached to the session's hub, or the spawner has a ceiling and the spawner's
node is connected. It is read afresh on every poll of a parked call, so a laptop
that goes away un-parks the call at the next slice. Nothing dials.

When a refused call is about to park, `escalate.Config.parked` is told the
record's identity and the instant the window closes, and the session writes a
row `delegate/outbox/escalation/{id}/{seq}` and rings the delegate drainer. A
row is written only when the laptop could answer, so a call that settles in band
leaves nothing behind.

### `ChildEscalation(parent, child, record, reply)`

Box to laptop. `record` is the protocol's own `EscalationRecord` at the `seq`
the box holds it, with `admitted` set to the part of `denial.wanted` that the
ceiling admits. The key is `(escalation_id, seq)`. The laptop's `ChildHost`
admits it as it admits mail: the parent's Agency finds the stub by the child's
strand name, whatever state the stub is in, and checks that the message came
from the node of the orchestrator the stub names. So it may arrive before the
answer to the `Spawn`, and the host never reads a handle.

The laptop files it as `remote-escalation/{orchestrator}/{id}` with the
orchestrator as `placement` and the `escalation_id` prefixed by it, under a
compare-and-set that writes only if the record's `seq` is above the filed one.
A late copy of an older record, a repeat, and a decided record followed by the
pending one it replaced all leave the newest. A record whose status is not
`pending` (decided or consumed) is filed the same way, and the cut selects only
pending ones, so the card clears.

The drainer's rules for the row:

| Event | What the pass does |
| --- | --- |
| Record pending at the row's `seq`, laptop has not acknowledged it | Sends it. An answer marks the row acknowledged. Silence or `ParentSessionNotOpen` leaves it. A final refusal drops the row. |
| Record pending, acknowledged | Nothing, and the pass stays owed, because a decision can come at any moment. |
| A newer raise replaced the record (pending at a higher `seq`) | Drops the row. The newer raise has its own. |
| The park window closed | Drops the row, without sending. Nobody is parked on the answer. |
| Record decided or consumed | Sends the decided state once, then drops the row. |

### `Resolve(parent, child, escalation_id, decision, expected_seq, decided_by, reply)`

Laptop to box. `decision` is `Approve(grants, action, scope: Once | Session)`,
`Deny`, or `Forget(grant)`. `decided_by` is the principal's digest and display
name as text. It is kept on the box as provenance and the box never resolves it
to a principal of its own: it authenticates nothing there.

The box serves it through the `SpawnHost` and the delegate session's hub, which
judges it on its own turn (`client/remote_decision`), in this order:

1. The spawner has a ceiling. Otherwise `Refused("outside the spawner's approval
   ceiling")`.
2. The record exists, was raised by a descendant of `^{parent.strand}`, is
   pending, and is at `expected_seq`. Otherwise `Refused` for an unknown record
   or a child that is not the parent's, and `Stale` with the record as it now is
   for a moved question.
3. For `Approve`: the echoed action is the record's, and every grant is in the
   record's wanted list (`Stale` otherwise, as for a local operator), and every
   grant is inside the ceiling (`Refused("outside the spawner's approval
   ceiling")`, and the record stays pending for the box's owner).
4. One compare-and-set at the `seq` read in step 2, through the same
   `api.approve_escalation_at` a local operator's approval uses. A session
   approval commits through `api.approve_escalation_with_fact_at`, so the
   approval and the remembered grant land together or not at all.

`Resolve.child` is carried for the laptop's own bookkeeping and is unused on the
box, which judges the record's scope against the parent alone.

The paths of an approval's grants must be their own canonical paths on the box
(the rule `permissions.revalidate` applies to a remembered grant) before the
ceiling is asked, because the ceiling compares text and a symlink under a root
can lead outside it.

`Forget(grant)` is admitted only for a grant that carries `Spawner` provenance
from the same spawner, and removes it in one guarded transaction.

The decided state reaches the laptop through the same outbox row, so the card
clears without waiting on the answer to `Resolve`.

### Session scope and its provenance

A session approval is remembered in the delegate session's own
`client/permission_grants` fact, in that session's store, with a new provenance
variant `Spawner(spawner, principal, at_ms)`. Dispatch reads standing authority
as it does for any session (`docs/architecture/approvals.md`), so the grant
reaches later calls of every child of that parent on the box, and no other
session, because no other session's store holds it.

When a delegate session opens, every remembered grant with `Spawner` provenance
is re-checked against the spawner's current ceiling and the ones outside it are
dropped and logged. Narrowing the ceiling and restarting the daemon revokes what
the old one let through. The grant is not re-checked while the session is
resident: a restart is already how a `[spawners]` change takes effect. A grant
the box's owner remembered, or that has no recorded approver, is never touched.
The grants are deleted with the store on `Release` and by the retention sweep.
The box's owner can also forget them from the delegate session's own list
(protocol-change/073).

A session approval remembers filesystem roots and full network, as it does
locally (`permissions.remembering`). A request whose admitted grants are
anything else, such as a limit, offers once only. Unlimited wall time is never
admitted by a ceiling, so the exact-action wall consent is not reachable from
the laptop.

### Client control protocol

`escalation` and `stale_approval.details.escalation` gain two optional members,
and `escalation_id` gains a meaning for a record that is not this session's own
(`docs/client-protocol.md`, sections 4.9.6 and 5.10):

- `placement`: the orchestrator the question was raised on.
- `admitted`: with `placement`, the grants of `denial.wanted` that the ceiling
  admits.
- `escalation_id` is `<placement>/<id there>` and `seq` is the other
  orchestrator's. `approve` and `deny` take those values unchanged. The gateway
  routes a command whose `escalation_id` names a filed request to the other
  orchestrator in a task of its own, so the hub never waits on the network, and
  replies when the answer arrives. The reply is `committed`, or a
  `stale_approval` carrying the box's current record, or `bad_request` with the
  box's reason.

Absent members read as absent, so a client written before this change renders a
record with a placement as an ordinary question whose id contains a slash and
whose approve it cannot make succeed (the grants outside `admitted` are
refused). That is the defect of an old client with a new server, and a client
that does not know a record's `placement` MUST NOT offer to approve it.

The terminal's approval card and the web page's drawer show
`<child> @ <orchestrator>` where a local card shows the asking strand, offer the
session choice only when the admitted grants can be remembered, and list the
grants outside the ceiling greyed, with the reason. Every name is a text node;
no new event class or content-security change is needed.

### Not built

`Forget` is a message the box admits and `Reach.resolve` can send, but no wire
command or card on the laptop sends it, because the laptop does not list what
the box remembers. Withdrawing a spawner's grant today is the box owner's list
(protocol-change/073) or the next open after narrowing the ceiling.

## What it costs

- Two port constructors and a new reserved prefix on each side.
- A parked call on the box costs one row, one send and one decided-state send,
  and the delegate drainer ticks every five seconds while a row is waiting.
- The hub gains a message and a pending-decision table, and the gateway reads a
  second prefix for snapshots, events and the cut.
- The ceiling is a second policy file to keep honest: a key added to
  `broker/policy.Grant` must be given a bound or the box does not compile.
- The laptop's copy of a question can be stale: after the park window closes
  without a decision, the card stays until the child's record changes or a
  decision answers `Stale` with the current record. The records are small and
  go with the session.

## Decisions taken, with the owner's rulings

- Laptop-side forget of a session grant is built as `Resolve(.., Forget(grant))`
  (ruling: build it). Its wire trigger on the laptop is not built, see above.
- A remembered `Spawner` grant outside a since-narrowed ceiling is dropped at the
  next open of the delegate session and not while it is resident (ruling).
- `decided_by` crosses as text and is provenance only (ruling).

## Model

No change to the P model. The single-consume state machine that makes an
approval spend once is `broker/escalation`'s and runs on the box, unchanged. The
laptop's filing is a monotonic register (the newest `seq` wins), and the one
message the model would add, a decision, is judged by that same machine on the
box: a decision at a stale `seq`, or after a consume, is refused by the same
compare-and-set that refuses a second local operator.
