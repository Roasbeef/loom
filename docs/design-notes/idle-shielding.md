# Idle shielding: closing a resident session's assembly while it is unused

Status: **a proposal, not a decision**. Written against `main` at `e6e1de206`
on 2026-11-07, after the `[daemon] capacity` key work raised the question of
what a large capacity number costs. Nothing here is implemented; every claim
about existing machinery cites where it lives today.

## 1. The question

`[daemon] capacity` bounds *occupied* session slots: a closed session frees
its slot at once, and the number has nothing to say about sessions that
merely exist. What the number does buy is the right to hold many sessions
*resident* at once, and residency is what costs memory: a resident session
holds its assembled runtime — the tool holder, the strand, the gateway, the
compaction hooks — whether or not anyone has touched it in the last hour.

Today only one kind of session gives residency back when it goes unused: a
delegate session closes after its spawner's `idle_close_s` (an hour by
default, `client/spawners.gleam:166`), and the next spawn or join reopens it
and pays the open again. An ordinary session a terminal or the web view
opened stays resident until somebody closes it, and the owner's sidebar
counts it against the slots forever.

Idle shielding is the proposal to give ordinary sessions the same shape: an
idle resident session closes its *assembly* — the processes and heaps —
while keeping its *durable state* and its slot identity, and the next
message reopens it. The durability makes this honest: the transcript, the
strands, the notes are all in the session store already, and a reopen
rebuilds the assembly from them the way a daemon restart does today.

The distinction from what already landed matters and is easy to miss.

- **Actor hibernation** (`daemon-memory.md`, 2026-09-20 sections at 1400 and
  1741) shrinks a *quiet actor's heap* inside a live session. It is landed:
  the strand, the advisor, the agency, extension hosts and writers all
  hibernate. It does not free the session's assembly, the holder, or the
  slot's cost; it trims the idle part of it.
- **Slot-level idle close** is what `idle_close_s` does to a delegate
  session, and what this note proposes to generalize. It stops the
  session's runtime and frees the memory; the identity, the store and the
  slot bookkeeping remain.

## 2. What exists to build on

Three pieces of machinery already answer the hard parts of the reopen, which
is why this is a design note rather than a research problem.

**The parked builder.** A session opened while its domain is closing is
parked as an `Opening` operation and activated when the domain publishes
services (`daemon/manager.gleam`, the `DomainPreparing`/parked-builder
sections around lines 483-622). Reopen-on-arrival is the same shape with a
different trigger: the first message for a shielded session parks an open
and the sender waits for publication. The census and the domain book
already distinguish a slot that is `Opening` from one that is resident, so a
reopening slot reports honestly rather than pretending to be live.

**Reopen is already a proven path.** A daemon restart reopens every session
that was resident when it stopped — the same durable store, the same
assembly. `startup-and-memory.md` measures what a reopen costs (a prime from
a high-water of zero was the expensive part, and it is repaired: the reopen
no longer decodes every entry). Shielding is therefore not a new failure
mode; it is asking the existing reopen path to run while the daemon is up.

**The delegate precedent.** `idle_close_s` is the same policy with the
spawner as the authority for "idle". The sweep that enforces it
(`manager.gleam` around 5052) already answers: how long, who says, what
happens to children. What it lacks for ordinary sessions is an *idle
definition* — a delegate is idle when its spawner is silent, which is a
fact the daemon can observe; an ordinary session's idleness has to come
from its own traffic and its attached clients.

## 3. The design questions, in the order they bite

**Who is idle?** The natural definition: a session with no attached client
(tenor, terminal, or web lane), no running operation, no live tool call or
satellite, and no message for the idle window. Each part is observable —
attachment counts the root already tracks, the agency's live children, the
tool holder's in-flight fetches — but the conjunction has to be a single
check the sweep can make without touching the session, the way the delegate
sweep reads the spawner's silence rather than asking the session anything.

**What does the sender see?** A message arriving for a shielded session must
not fail; it parks an open and waits, the way a message for a session whose
domain is closing already does. The sender-visible contract is the honest
one: a reply may take the open's latency, and the census says `Opening`
while it does. The alternative — refusing and letting the client reopen —
pushes the reopen onto every client and makes shielding visible as errors,
which is what the delegate path deliberately avoids.

**What stays and what goes?** The slot row, the session id, the catalogue
row and the store stay. The assembly goes: the tool holder (its custody is
already an ordered teardown kind, `client/internal/instance_owner`), the
strand, the gateway, the supervised children. Unsaved work must not exist at
this boundary — everything the assembly holds is a cache over the durable
store, which is the two-channel doctrine doing the work this design rests
on. A background job the session started is the one deliberate exception:
it clears under a sibling step and must keep running, so a session with
live jobs is not idle (the delegate sweep already treats children this
way).

**Who decides the window?** The delegate precedent suggests a table key
rather than a flag — `[daemon] idle_shield_s`, say, absent meaning never.
That keeps the capacity question and the shielding question as two separate
operator choices, and lets the sidebar keep counting slots the same way
whether or not sessions shield.

**What does the census report?** Today the sidebar's "N of M slots" counts
occupied slots. A shielded session still occupies its slot — reopening
needs the identity — so the number does not change; what changes is the
daemon's memory per shielded slot, which falls from the resident cost to
the slot-row cost. A session that is `Opening` after a shield reads as
opening, which is what it is.

## 4. What this does not settle

- Whether the open latency is acceptable for the web view's lane polling,
  or whether lanes need to hold a shielded session resident the way
  terminals do. The delegate path's answer — reopening pays the open again,
  and the sweep is hourly so the cost is rare — may transfer, but a web
  page polling a shielded session would defeat the shield by construction.
- The interaction with moves: a session being moved is not idle by
  definition, and the move path already has its own "slot stopped" states
  that shielding must not race with. The parked-builder machinery is shared,
  so the two need one ordering argument, written down before either changes.
- The measurement the Oct 10 resource report still owes: an
  installed-shape census of what a resident session costs *after* the copy
  repairs. Shielding's value is a multiple of that number; if the current
  cost is small the design is not worth its complexity, and if it is the
  ten-MiB order the note's earlier sections describe, shielding is what
  makes a capacity of hundreds cheap rather than a machine purchase.

## 5. Why a note and not a PR

The reopen path exists and is proven; the idle definition and the
no-races-with-moves argument do not, and both are the kind of thing this
repository writes down before it builds. The natural order is: take the
measurement (the Oct 10 follow-up), then decide whether the per-session
cost justifies the mechanism, then write the idle definition and the move
ordering as the proposal's frozen part, and implement against the parked
builder.
