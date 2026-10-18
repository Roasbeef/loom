# protocol-change/089: configuration edits in the proposal queue

**Status**: PROPOSED 2026-10-18. **Affects**: the `proposals` board (a second
`kind`, `config`, whose `target` is an absolute path) and the `propose` tool (an
optional `target` argument). No command, event or other field changes.
**Builds on**: [086](086-memory-proposals.md), which reserved this kind "for
the work that carries a configuration edit door". **Implemented**:
`tools/propose`, `client/proposals`, `client/config_watch`, `client/serve`,
`client/gateway`, `session_view/proposals`, `tui/proposal_panel`,
`web_view/view/proposals`.

## Problem

An operator iterating on `loom.toml` with an agent has two bad options. The
agent can say what to change and the operator edits the file by hand, or the
operator grants the agent a write to a file outside the workspace, which the
base policy rightly protects. Either way the edit only takes effect when the
daemon restarts, because a session reads its configuration once, at open.

Two branches attacked this separately. One reloaded a session's model
configuration under it, pinning a revision per operation so a run in flight
kept the configuration it started with. The other added a `loom_config` tool
whose edit raised a blocking escalation, an exact-diff approval card in both
clients, and a refresh of the live configuration after the write.

## What was considered

- **Swapping configuration under a live session.** Every role route, the
  advisor and the tool registry are built once when a session opens, which is
  why protocol-change/082 switches a profile by reopening the session. A hot
  swap reaches only the parts a pin can be threaded through (endpoints, limits,
  routing) and leaves the rest boot-owned, so an edit would apply partly and the
  operator would have to know which part. It also needs a revision pinned
  through every hook an operation touches.
- **A blocking escalation per edit.** It parks the run while a person reads, and
  086 already rejected escalations for suggestions: they belong in a queue a
  person reads when they choose, not in the list of questions that unblock work.
  The escalation record also binds to sandbox grants, so an edit door needs
  special cases in the approval projection, the retry budget and both clients.

## Decision

A configuration edit is a proposal of kind `config` in 086's queue. `propose`
takes `target: "config"`; the host fills in the session's own configuration
path and never reads one from the model. The edit is checked twice with the
session's own loader (`serve.check_config` under its profile and model): when it
is filed, and again against the file as it stands when it is approved. The digest
check and the exactly-once match are 086's. An approval writes the file
atomically, keeps its permission bits, refuses a symbolic link, and is accepted
only from a session whose own configuration is the target, so a stored row can
never point the host at a file it does not already load.

A written file is picked up by `client/config_watch`, which every daemon session
with a configuration file runs. It reads the file once a second, acts when two
reads agree, checks the text with the same loader, and tells the hub, which
reopens the session through 082's restart once no strand is running. The same
path takes an edit the operator makes by hand.

## What it costs

- A reload is a reopen. Attachments close: the terminal reattaches by itself and
  a web page must be reloaded, as after a profile switch. Background jobs end with
  the session.
- One daemon-wide file can be loaded by sessions of different domains, whose
  decisions hold different memory leases, so two approvals against one file in
  two domains are serialized only by the digest check. That check is optimistic
  against an operator's editor too.
- A pending row of a kind a client does not know is no longer offered approve
  and reject (086 said so; `decidable` had not checked it).
