# protocol-change/129: `agent_spawn` with `on` must name its context

**Status**: PROPOSED 2026-11-20. The owner accepted autonomous protocol changes
for the distributed completion work (#1137).
**Affects**: the `agent_spawn` tool's argument contract: a call with `on` and no
`context` is now refused when the caller's workspace could have been sent. The
`context` description gains one sentence. `tools/agent.Provenance` gains the
variant `Unstated`, and `client/agency.Seeding` gains the field `offer`. No wire
message, stored record, command or `loom.toml` key changes.
**Raised by**: the two-machine drive of #1137 (2026-11-19, criterion 3, run 1).
**Builds on**: [107](107-state-transport.md), which added `context:
"my_workspace"`.

## Problem

A laptop session whose model called `agent_spawn` with `on: "box"` and no
`context` started eight children on the box. `context` defaulted to `fresh`, so
no workspace was sent, and the eight children ran unseeded as strands of one
delegate session on one executor. No commits came back as refs, and the parent
wrote the files itself. When the prompt named `context: "my_workspace"`, all
eight children were seeded. The tool had accepted a call that almost always
meant the opposite of what it did, and returned success.

## What was considered

1. **Default to `my_workspace` when `on` is given.** The default would be right
   for the drive. It is wrong where the receiving spawner has `seed = "none"`
   (the default of that key), which refuses any spawn that carries a state: a
   call that worked now fails after a capture the model did not ask for. The
   caller cannot know the receiver's `seed`, because the table is the receiving
   owner's and is not sent. A capture also holds the workspace's gate for the
   copy, which is a cost the model should choose.
2. **Refuse an omitted `context` with `on`, with an error naming both choices.**
   Nothing is captured or sent, and no child starts in the wrong state. The cost
   is that a model calling `on` for a spawner with `seed = "none"` must write
   `context: "fresh"` once.
3. **A better description alone.** The drive's model read the description and
   still left the argument out. A description cannot make the state
   unreachable.

## Decision

Option 2, narrowed to where the choice exists. The Agency refuses a spawn with
`on` when all of these hold: the call named no context (the tool decodes an
omitted `context` to `Unstated`; `fresh` is a different value), the call is a
tool call and not a code-mode program (a program always names its context), and
the session's `Seeding.offer` is `Offered`, meaning its workspace is on this
machine and a capture is set up. The refusal says to pass `context:
"my_workspace"` or `context: "fresh"`. For any other session, and for a child of
this session, `Unstated` is `Fresh`, as before. The tool description says so.

## What it costs

A call with `on` and no `context` that worked before is now refused once, for a
session with a capturable workspace. A recovered session that replays such a call
before its stub is found is refused as well; the model's next call names the
context. A spawner with `seed = "none"` is reached with `context: "fresh"`. The
receiving side is unchanged: a request without a state under `seed =
"workspace"` is still accepted, because a fresh child there is a legitimate
choice, and the owner's setting is a ceiling.
