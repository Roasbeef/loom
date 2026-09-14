# protocol-change/033 — Escape halts held input until the operator speaks

**Status**: ACCEPTED 2026-09-14 · **Affects**: the held-input behaviour of
`abort` (Part 1.3 session protocol v2); no command is added and no wire
shape changes · **Supersedes**: the drain ruling of
[032](032-abort-held-batch.md); its batch and content guarantees stand ·
**Implemented**: `client/gateway`, `tui`

## Problem

Under 032 an explicit `abort` marks the strand's held queue `AllHeld`, and
the gateway admits that whole queue as one successor run at the next idle
transition. The idle transition is the aborted operation retiring, so the
successor starts the moment the abort lands, with no further input from
anyone. An operator who presses Escape to *stop* therefore watches the
strand stop and immediately start again on whatever they had queued
before they changed their mind. Escape reads as "skip ahead", when the
operator meant "halt, and wait for me".

The client made the same assumption from its side: after Escape it flipped
the composer into steer mode and the next Enter went out as a steer, ahead
of the held prompts rather than after them.

## Decision

**1. `abort` halts the queue instead of releasing it.** `HeldDrain` gains a
third variant, `Halted`, and an explicit abort marks an existing queue
`Halted` rather than `AllHeld`. `drain_strand` admits nothing from a
halted queue, however idle the strand becomes. Every held message keeps its
identity, revision, author, content and position, so reads and
compare-and-replace edits of the queue behave exactly as under 024 while
the halt holds.

**2. The next client submission on the strand releases it.** When a
`prompt`, `prompt_content`, `follow_up` or `steer` from any authenticated
client joins a halted queue, `release_halt` flips the queue to `AllHeld`
and the ordinary pull-driven drain then admits the whole queue — the
messages held when the operator stopped the run and the message they typed
afterwards — as one runtime admission, in the existing order: steers first,
then ordinary turns, FIFO within each. A prompt lands last, which is what
"send the queue and my new message" means; a steer lands first, which is
what steering has always meant. The release belongs to the strand, not to
the connection that pressed Escape: any client's next submission lifts it.

The queue bound does not apply to the release. A strand holds four ordinary
messages and four steers (`held_per_strand`), and a submission that lifts a
halt is exempt from that count, because the queue it joins drains on the
next pull rather than growing. Refusing it would make Escape followed by
Enter the one submission a full halted queue can never accept: no command
shortens a queue, and a halt ends no other way.

**3. An empty queue at abort is unchanged.** A strand with nothing held has
no queue to halt, so 032's ruling that an empty queue carries no intent
stands: input typed after such an abort keeps the ordinary one-head drain.

**4. The client sends a prompt, not a steer.** After Escape the terminal's
next Enter goes out as an ordinary `prompt`, and its status line says so:
`stopped · enter sends held input with your message`. The legacy
client-side hold for a host without a gateway queue is retained
unchanged.

## What is deliberately not in this change

The halt is a gateway property of held *client* input. A run started by
something other than a client submission — a live parent's downward
`send_to_strand` into an idle child, an advisor `block`, or a `wake = true`
schedule firing on an idle strand (`client/schedulescan`) — goes through
`runtime/api` and never sees the queue, so it is not halted here. Making
those respect an operator's Escape is a `runtime`-level question (a paused
mark on the strand cell) and is left open in `docs/next.md`.

## Cost

One variant and two functions in the gateway, and a two-word change in the
client's post-Escape path. The 032 acceptance tests were rewritten rather
than kept: their premise, that the batch commits with no further input,
is the behaviour this change removes.

## Acceptance

After `abort`, the aborted operation retires, the strand reads idle, and
the queue still holds every message it held. A subsequent `prompt` from
any client commits every held message and then that prompt, each under its
original author with its full content, in one admission before a parked
replacement provider is released. A queue filled to its ordinary bound
before the abort still accepts that release, and every message it held
reaches the successor with it. An empty-queue abort followed by two prompts
still admits only the first (032's existing arm).
