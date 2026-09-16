# 041: Remembered permissions in the approval dialog

Status: accepted for implementation after independent design review.

## Problem

Approval details are an inspection panel rather than an automatic decision
dialog. Approving a request authorizes one call but does not remember its
filesystem or network permission for later calls in the same saved session.

## Decision

A newly pending request opens a dialog containing the captured action and
exact requested grants. The operator can allow once, allow for this session,
or deny. Opening or dismissing the dialog is not approval. Every decision
submits the sequence, action and grants captured when that dialog opened.
A refreshed request cannot silently replace the question being answered.

The existing `approve` command accepts optional `scope: "session"`; omitted
scope and `scope: "once"` retain existing one-call behavior. Unknown scopes
are refused. Session approval is available only when all displayed grants
are canonical readable/writable paths or full network access. Limits,
environment variables, scratch and proxy settings remain one-call grants.

The runtime writer commits approval and the union of remembered grants in
one transaction, guarded by both the displayed escalation sequence and the
previous grant-fact sequence. A conflict writes neither and requires a fresh
question; the server never retries the human's stale decision. The runtime
API receives an opaque reserved-fact update and remains independent of broker
policy. The authenticated gateway validates the echoed grants before forming
that update.

Remembered grants use a separate reserved session fact. Exact file grants,
including missing writable leaves, must not enter the directory-only fact
used by `/add-dir`. Dispatch validates the stored canonical paths, snapshots
the grants, and adds them to the jail policy and explicit native filesystem
authority. Protected writes remain denied. Session reopen preserves the fact;
other sessions and already-running executions retain their own authority.

## Kernel boundary

Native pre-I/O refusals and declared shell/code-mode permission preflights
can raise an exact approval request automatically. A raw denied syscall in
an arbitrary shell command does not report its canonical resource and grant
through the current executor protocol. Stderr is not a trusted policy event.
Such a failure remains a tool result; the model may submit a new invocation
with declared permissions. An in-program code-mode capability refusal also
remains a program result. Neither case automatically replays earlier effects.

## Review and cost

Independent design review required the two guarded writes, exact echoed grants,
a separate fact for file grants, invocation snapshots and captured dialog
consent. Those requirements are incorporated above. No new policy actor or
syscall monitor is needed. Dialog deduplication uses both request ID and
sequence, since a reopened request may reuse its ID.

Regression coverage must prove stale and concurrent answers cannot save
permissions, once-only approval does not save them, exact file authority
survives SQLite reopen without authorizing a neighbor, and the TUI submits
the captured question rather than a newer unseen record.
