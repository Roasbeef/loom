# Async execution and peer collaboration

`code_mode` can keep a sandboxed BEAM process (a satellite) alive after its
launching tool call returns. A program can retain typed actors and receive data
from later turns. On the orchestration seam, it can also start children and
recover their durable results through named workflow steps.

For example, a review program can start security and performance reviewers,
receive another commit to inspect, and collect each reviewer's result. Peer
links let agents exchange messages within a session or across resident sessions.
The owner grants those links separately from child ownership.

## Launch and interact

The existing synchronous invocation remains the default. A background launch
uses the same source, seam, policy, approval and budget fields with
`"mode": "launch"`. The response contains an execution `id` and fixed deadline.
Running means admitted; compilation and node startup may still be pending.

```json
{"mode":"launch","seam":"workspace","program":"import cap/report\npub fn main() { report.text(\"done\") }","within_ms":60000}
```

Subsequent calls use `"handle": "<id>"` and one of these modes:

| Mode | Additional fields | Meaning |
|---|---|---|
| `send` | `value`, any JSON value | Commit the next input and return its sequence |
| `check` | none | Read lifecycle and any result without waiting |
| `join` | optional `within_ms` | Wait up to 30 seconds for a terminal record |
| `cancel` | none | Close admission and request cancellation |

Only the owning strand can interact with a handle. Sending data cannot replace
the source, add grants, change the seam, or renew the original deadline. Each
session admits at most eight live executions. An input journal holds at most
128 entries and 65,536 encoded bytes. Reads are non-destructive:

```gleam
import cap/execution
import cap/report

pub fn main() -> report.Outcome {
  case execution.receive(after: 0, within_ms: 30000) {
    Ok(execution.Message(sequence: _, value: value)) -> report.value(value)
    Ok(execution.TimedOut) -> report.text("No input yet.")
    Ok(execution.Closed) -> report.text("Execution closed.")
    Error(reason) -> report.text(reason)
  }
}
```

A longer program retains the returned cursor and decodes each value into its
own typed actor message. Repeating a read with the same cursor returns the same
input. Repeating a send appends a new input; sends are not deduplicated.

An execution moves through `Starting`, `Running`, `Draining`, and either
`Finished(result)` or `Lost(reason)`. Loom records `Finished` only after the
managed scope has confirmed shutdown and its owned children have terminated.
That check also includes background executions started by those children.
Cancellation and expiry first refuse further child admissions, then abort
effects.

`Lost` means the satellite process cannot be recovered. Its program is not
replayed, and any uncertain native effects remain uncertain. Recovery retries
cleanup of owned children. A daemon restart never reruns arbitrary workspace
effects.

## Named child workflows

Background programs on the `orchestration` seam can import `cap/workflow`.
`workflow.step(run, version, input, name, assignment)` starts or recovers one
named child. Use `cap/strand.wait` to read its durable outcome and validated
result. The run name belongs to the launching strand. Version and input are
immutable for that run, and the child assignment is immutable for that step.

```gleam
import cap/report
import cap/strand
import cap/workflow

pub fn main() -> report.Outcome {
  let assignment =
    strand.assignment(purpose: "security", brief: "Review the proposed change.")
  case workflow.step("review-42", "v1", "commit-sha", "security", assignment) {
    Error(reason) -> report.text(reason)
    Ok(child) -> case strand.wait([child], within_ms: 10000) {
      Ok([strand.Ready(report: text, ..)]) -> report.text(text)
      Ok(_) -> report.text("Review is still running.")
      Error(_) -> report.text("Could not join the review.")
    }
  }
}
```

Step identity does not depend on call order. Relaunching an orchestration
program under the same strand and names recovers the same operation, including
its failed outcome. An intentional retry uses an explicit new step name such
as `security-retry-1`; unrelated completed steps retain their identities. New
workflow input or an algorithm version requires a new run name. There is no
implicit prefix replay, replay of shell effects, or persistence of actor heaps.

Ordinary `strand.spawn` retains its call-site identity semantics. Async children
belong to their execution: they survive the launching turn, but closing the
execution cancels them. Explicitly detached children retain the
existing detach behavior. Child admission still obeys depth, fan-out, tool and
model selection rules, and cannot exceed the execution's remaining deadline.

## Peer messaging

The owner grants a directional link from one session and strand to another
through the authenticated v2 daemon control connection. A reverse link requires
a separate grant. Session membership alone cannot grant links. The current
daemon epoch and canonical session IDs are required:

```json
{"v":2,"id":1,"cmd":"peers.link","body":{"source_session":"<canonical-id>","source_strand":"main","target_session":"<canonical-id>","target_strand":"reviewer","wake":"busy_only","epoch":"<current-epoch>"}}
```

Peer messaging is disabled until the owner grants a link. There is no automatic
link for sessions in the same repository, and granting A-to-B does not grant
B-to-A. Both sessions must be open when the owner creates the link.

`busy_only` permits messages during an existing run. `may_wake` also permits a
new run on that exported strand. Neither opens a saved session. A link permits
neither joining the peer nor cancelling it, changing its configuration, or
using its filesystem. Same-session sibling links use the same controls.

An owner-authenticated script or bridge can send through the same control
connection with `peers.send`. It supplies the same source and target coordinates,
plus `message_id`, `text`, and the current `epoch`:

```json
{"v":2,"id":2,"cmd":"peers.send","body":{"source_session":"<canonical-id>","source_strand":"main","target_session":"<canonical-id>","target_strand":"reviewer","message_id":"review-42-finding-1","text":"The review found a missing cancellation check.","epoch":"<current-epoch>"}}
```

The owner selects the strand on whose behalf the script sends. The command
still requires that strand's outgoing link and the recipient's grant. It uses
the same durable receipt and wake policy as the model tool. Both sessions must
be resident; sending never opens a saved session. The harness reads source
metadata from the resident endpoint and catalogue instead of accepting it from
the request. A member credential cannot use this command.

The model gets three tools: `peer_roster`, `peer_send`, and `peer_describe`.
`peer_send` takes `session`, `strand`, `message_id`, and `text`. The program API
is `cap/peer.roster()` and `cap/peer.send(...)`, returning JSON text. Each program
may admit at most 128 calls of each peer capability. Message IDs are 1–128 bytes;
message bodies are at most 32,768 bytes.

Reuse a message ID only to retry the exact same target and body. The recipient
checks that its grant has not changed, then commits the receipt and message in
the same transaction.
A lost acknowledgement can therefore be retried without enqueueing twice.
Reusing an ID for different content is refused. Revoking the grant can also
refuse a retry, even when the original message was admitted. A receipt proves
that the message was stored; it does not prove that the model read it or finished
the requested task.

The harness supplies the sender's session, strand, and observed metadata. The
sending model cannot override that identity. Message text and model descriptions
carry no authority.

Discovery shows linked resident and saved sessions, catalogue name and workspace,
exported strands, current operation and state sequence, latest terminal result,
and a separately labeled model self-description. Git root, common directory and
branch are timestamped **activation observations**, not a live branch guarantee.
Unavailable or deleted targets remain individual unavailable rows. Repository
similarity never creates a grant.

`peers.unlink` uses the same coordinates and epoch, without `wake`. The source
must be resident. A saved or deleted recipient does not prevent removal of the
source's outgoing link; the response explicitly reports that its recipient-side
grant could not be removed. Without the outgoing link the source cannot send.
A later explicit link replaces the exact recipient permission before publishing
outgoing discovery again.

Terminal presentation, saved-session outboxes, cross-machine transport and
arbitrary effect replay are deferred. The core APIs above work independently
of a terminal redesign.
