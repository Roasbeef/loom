# Human input priority and operation-scoped stopping

Status: implementation of the approved developer-experience control semantics.

## Problem

Human steering previously entered the current operation's durable input queue.
It waited for a checkpoint, and cancellation discarded it along with pending
follow-ups. The TUI then held replacement text locally, waiting for a terminal
event which modern snapshot delivery need not expose. A busy successor could
also receive a delayed abort intended for its predecessor.

## Decision

The client gateway owns human pending input. `steer` puts a message before
ordinary queued turns and requests cancellation of the observed operation.
`follow_up` and a busy `prompt` wait for their turn. Escape stops current work;
all host-held input remains queued and drains after runtime reconciliation.
An idle steer starts a turn. Arrival order is preserved within each priority.
Each strand admits four normal queued inputs and four steers, so a full normal
queue cannot prevent the operator from steering.

The queue retains the submitted message and its original author. Its existing
protocol-018 lifetime remains the gateway lifetime: `queued` transfers custody
to hub memory, while `admitted` denotes durable acceptance. A gateway restart
loses unadmitted input. Internal `runtime/api.steer` remains the cooperative,
durable checkpoint input used for agent mail and scheduling.

`runtime/api.abort_operation(runtime, operation)` targets one observed operation.
`api.abort(runtime)` captures the current identity before sending. The internal
strand request carries that identity through every stale-commit retry. An idle
strand or a different current operation makes the request obsolete and does not
interrupt effects. A successful target marker still precedes effect cancellation.

Snapshots add optional `pending_inputs`, an ordered array of `{id, strand, kind,
text}`. `id` combines the gateway connection and request ID; `kind` is `steer` or
`queue`; `text` is a UTF-8 excerpt of at most 512 bytes. The full message remains
in the host queue. Empty arrays authoritatively clear the display; absent fields
retain compatibility with old recordings. `input_queue_changed` is an ephemeral
refresh notice, independent of the durable sequence cursor. Clients replace
queue rows instead of matching submitted text against new transcript entries.

The TUI retires its interrupt indicator when a coherent cut no longer names the
stopped operation, including when a successor is already running. Modern
replacement input is sent immediately to the host priority queue.

## Alternatives and cost

Keeping a replacement only in the terminal hides its priority from other peers
and loses it on disconnect. Putting it on the cancelled operation makes its
survival depend on abort timing. A new durable pending-operation kind would
expand the machine and recovery protocol beyond the existing host queue.

This change reuses the gateway queue and strand cancellation owner. It adds no
actor, timer, poll loop, or retry domain. The tradeoff is explicit: unadmitted
human input has the same transient lifetime as protocol-018 queued prompts.
