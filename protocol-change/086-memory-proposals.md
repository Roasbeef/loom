# protocol-change/086: a queue of proposed rules, decided by the owner

**Status**: PROPOSED 2026-10-11, for the memory-as-recall work
(`docs/design-notes/memory-recall.md`, slice C). **Affects**: the session wire
(two commands, one snapshot and one pushed event), a new reserved fact prefix
(`proposal/`), a new origin in the system prompt
(`approved-proposal`), a new built-in tool (`propose`) and one new entry in the
event bus (`ProposalsChanged`). No existing command, event or field changes.
**Raised by**: the observation that `remember` writes a note nobody is asked to
act on, and that the only way a lesson becomes a standing rule is a person
editing a file by hand. **Builds on**: [056](056-goal-write-invalidation.md)
(a data-free invalidation after a durable write) and
[073](073-web-session-grants.md) (owner-only listing and decision commands over
a reserved fact). **Implemented**: `tools/propose`, `client/proposals`,
`client/protocol`, `client/gateway`, `client/system_prompt`,
`client/workspace_policy`, `events/bus`.

## Problem

A model working in a repository learns things that should bind the sessions
that follow: a command that must run before a push, a directory it must not
touch. It has two doors for this today. `remember` writes a note that reaches
later sessions as quoted context and binds nothing. The operator's own
instruction files bind, but only a person can edit them. A person reading a
transcript has nothing to hand them the model's suggestion in a form they can
accept in one step.

The obvious answer is to let the model edit an instruction file. That gives the
strongest influence a model can have over its successors to the party that the
framing of the prompt is built to hold at arm's length, so the answer has to be
a suggestion that a person turns into a rule.

## What was considered

### Writing the workspace's AGENTS.md

The natural target, and the one the first version of the design named. Rejected
for three reasons, and the first would be enough.

In this repository `AGENTS.md` is a byte-identical copy of `CLAUDE.md`, made by
`cp`, and `make doc-check` fails when the two differ. An approval that wrote
one of them would break the gate, and one that wrote both would be an edit to
a file that is generated from the other. That is a fact about this repository,
but it points at the general one: a repository's instruction files are
authored by the people who own the repository, reviewed in its history, and
sometimes generated. A tool that appends to them from a session is editing
someone's source.

Second, the prompt frames `workspace` files as information about the code, never
as authority over the agent's behaviour, because a hostile or merely careless
project file must not be able to speak with the operator's voice. A rule a
person approved is exactly the thing that should speak with some authority.
Written into `AGENTS.md` it would be carried under the weaker framing, and a
reader could not tell an approved rule from the project's own text.

Third, the file is in the workspace, so a jailed process can write it. The
approval would be a decision to trust text that an unrelated process could have
changed a second later.

### Configuration, as a `[[rule]]` table

Rules are operator configuration. `client/rules` is explicit that the file is
the record and that a restart is how a change lands, and it never edits what the
operator wrote. Letting a session add a table would mean a second writer to a
file the operator edits by hand, with the merge conflicts that implies. It is
also a bigger change than this one needs, since a configuration rule fires on
events and what is wanted here is standing text. A kind that targets
configuration is left for the work that carries a configuration edit door.

### A blocking approval

`propose` could park the run until a person answers, as a refused call does
(`docs/architecture/approvals.md`). Rejected. A suggestion is not what the run
is waiting for, and a run held open for a rule it does not need is a worse
outcome than a rule filed for later. The same reasoning rules out raising an
escalation record: that would put a suggestion in the list of questions a person
has to answer to unblock work, where it competes with the ones that matter.

### Automatic application

Applying the rule when the model asks, and listing it afterwards for undo. Rejected: the
property worth having is that nothing the model said becomes a rule unless a
person read it.

### A file the host owns

Chosen. `loom-rules.md` lives beside the domain's memory store, derived from the
domain the way the digest sidecar is, and fixed by the host. The model's
argument schema has no field that could carry a path, and the tool never returns
one. The file is protected from every jail (`workspace_policy.protecting_rules`)
for the argument `protecting_memory` makes: the prompt carries it at the start
of every new session, so a file a jailed process could write would be a standing
instruction channel into all of them.

## Decision

### The tool

`propose` takes `old` (empty to append), `new` (at most 2048 bytes),
`rationale` (at most 1024 bytes) and an optional `source_entry`. `old` is at most
4096 bytes. There is no `target` argument. It validates what the arguments alone
can be checked for, asks the host to queue, and returns `queued as <id>`. It
never blocks, raises no approval or escalation and writes no file. It is
`replay: Never` (a replay would queue the suggestion twice) and
`execution_mode: Exclusive` (two in one batch would race for the last slot). It
runs on the owner's side, beside the store.

The host refuses in band, as a tool failure the model reads, when `old` is not in
the rules file, is in it more than once, when the edit would take the file past
16384 bytes, or when 64 proposals already wait.

### The proposal

```
{ id, kind, target, base_digest, old, new, rationale,
  source: {session, entry?}, created_ms, state }
```

`kind` is `rule`. `target` is `loom-rules.md`, a file name and never a path, and
the decoder refuses any other value, so a stored row cannot point the host
elsewhere. `base_digest` is `tools/hashline.digest` of the rules file's exact
text at proposal time, which is `cbf29ce484222325-0` for a file that does not
exist yet. `state` is `pending`, `approved`, `rejected` or `stale`; only
`pending` changes. A proposal is `stale` when the file no longer has
`base_digest` at decision time, or when `old` no longer matches exactly once.

Storage is one `fact.custom` cell per proposal, `proposal/<id>`, where `<id>`
is `prop-` and ten lower-case hexadecimal digits, in the domain's memory store
(`loom-memory.db`, beside `loom-rules.md`). The queue is the domain's: a proposal
made in any session is listed and decided from every session of the domain, and
`source.session` records which one made it. A session snapshot capture copies
only that session's own `client/` facts, so a queue a model can fill is never in
one and needs no reserved prefix in the session store.

Every write to the queue (a submission, a decision, the retirement of old decided
rows) happens while the host holds the memory store's writer lease, the lease
`remember` takes. An approval holds that one lease from reading the rules file to
marking the proposal, so two decisions in a domain run one after the other and
the second reads the file the first wrote. A caller that finds the lease held is
answered in band and may try again; nothing waits or retries. Listing takes no
lease. The cell is claimed on its absence when queued, and the decision commit
that marks a proposal also deletes the decided rows past the newest 100. A damaged
cell is left out of a listing and not counted.

### Commands, snapshot and push

`proposals_get` has an empty body. `proposal_decide` carries `{id, decision}`,
`decision` being `approve` or `reject`. Both are answered by a `proposals`
snapshot whose board is `{proposals, pending, limit, omitted?}`: the held
proposals newest first, the number pending over all of them, the queue's bound of
64, and `omitted`, an additive count of rows left out to keep the encoded board
within 48,000 bytes. The oldest decided rows go first and then the oldest pending
ones; `omitted` is absent or zero when nothing was left out, so a client that
predates it still decodes the board. The exact JSON is in
`docs/client-protocol.md` section 4.9.31.

A decision that finds the file moved is answered with the board in which the
proposal is `stale`, not with an error: the person asked for a decision and the
queue recorded the one the file allowed. An unknown or malformed id is
`bad_request`, a proposal that was decided already is `conflict`, and so is a decision made while
another writer holds the memory store (the message says the queue is in use and
to decide again; nothing was read or written), a rules file that cannot be read or written is
`internal` and leaves the proposal pending, and a host with no queue answers
`unsupported`.

`proposals_changed` is pushed with an empty body after a proposal is queued or
decided, as `goal_changed` is after a goal write (056): no board, no `reply_to`,
no `seq`. A client that is showing proposals reads the board again. The event
is a new `ProposalsChanged` on the bus's `Outputs` topic, published by the queue
after a successful write and relayed by the gateway to subscribed peers. It is
published under a key derived from the memory store's path, which every session of
the domain subscribes to, so a page open in a sibling session re-reads too.

### Authority

Both commands are the daemon owner's alone, as remembering permissions is (073).
An observer is refused as for every mutation (the commands are not reads), and
an authenticated member is refused with `forbidden`. The listing is model-written
text that a person is about to promote to a rule, and a member who could decide
would be adding standing instructions to the owner's repository.

### Approval

An approval reads the rules file as it is now and refuses to proceed unless the
file has the proposal's `base_digest` and `old` still matches exactly once. Both
are checked, and a failure of either marks the proposal `stale` and writes
nothing. Otherwise the host writes the new text beside the file and renames it
over, so a reader sees the old file or the new one. The write is on the host and
does not go through the workspace plane: the file is the host's, outside the
editable workspace, and it is the same file whichever machine the workspace is
on.

An empty `old` appends `new` as a new rule under a header the host writes,
`### Rule <id> (approved <date>, from session <session>)`, so the prompt can say
where each rule came from. A non-empty `old` is replaced by `new` in place and
the header of the rule it sits in is left as it was, so a replaced rule keeps the
date it was first approved. A rejection records the decision and touches no
file.

An approval writes the file and then marks the proposal. If the process dies
between the two, the proposal is still pending and the file has changed, so
deciding it again finds a different digest and marks it `stale`. A rule is never
applied twice. The one cost is that this proposal reads as stale although its
text is in the file.

Two sessions approving at the same instant cannot both pass the digest check,
because the second finds the lease held and is answered busy, or runs after the
first and reads the file it wrote.

### The prompt

The system prompt renders `loom-rules.md` after the operator's and the project's
instruction files, in a fence of its own:

```
<instructions origin=approved-proposal path=loom-rules.md>
### Rule prop-... (approved 2026-10-11, from session ...)
...
</instructions>
```

The fence follows the existing form, which writes no quotation marks so that a
prompt compared line by line needs no unescaping. The file is named by its name,
not its path. The `_repository_guidance` fragment of the default pack gains a
sentence saying what the origin means: rules a person approved, at most one block,
always last, and not outranking anything said above. The block is read whole and
bounded at 16 KiB. A file over the bound, or one that is not text, is left out of
the prompt with a warning and is never truncated, since half a rule is not what
anyone approved.

A session's prompt is pinned for its life, so an approved rule reaches the
sessions opened after the approval and not the running one. That is a property of
the pin, not of this change, and the documentation says so.

## What it costs

A model can fill the queue. The bound is 64 pending proposals and the next one is
refused in band, so the cost is a full list a person must clear, not an unbounded
file. Decided proposals are kept for the review pane, but only the newest 100:
every settlement deletes the older decided rows, oldest first, so the prefix
holds at most 64 pending and 100 decided rows and cannot grow without bound.

The reserved prefix is one more thing the owner's reads walk: a listing reads
every cell under it and sorts, and each submission reads it to count the pending
rows. With the bounds above that is a scan of at most 164 cells.

A proposal's `old`, `new` and `rationale` may not hold a control character other
than newline and tab, because those serve no purpose in a rule and inflate a stored
cell sixfold when escaped, and may not contain `<instructions` or `</instructions`
in any case or spacing, because an approved rule is carried inside that fence of
the system prompt and must not be able to close it. Both are refused in band when
the model files the proposal, and the fence text again when a person approves.

A replaced rule keeps its old header, so its date can predate its current words.
That is deliberate, to keep the edit exact, and a reviewer sees both versions in
the proposal itself.

A proposal approved after the file was edited by hand is stale even if the
edit was unrelated to its text. The digest is of the whole file because it is the
check that cannot be wrong; the alternative, matching only `old`, would approve
an append written against a file that has since changed meaning.

The wire gains two commands, a snapshot mode and an event, and no existing one
moves, so the protocol version stays 2 and an older client ignores the snapshot
and event it never asks for or receives. The bus gains a variant, which is
source-incompatible only for a package that matches the events exhaustively, and
none outside the gateway does. The default pack gains a sentence, which changes the
cached prompt prefix once, for every session, at the first release that carries
it.

## Verification

Tool validation, the queue's bound, the digest and unique-match checks, exactly-once
application, stale detection, rejection leaving the file alone, durability across a
restart and a damaged cell are tests over a real SQLite-backed runtime and a real
file (`client/proposals_test`, `tools/propose_test`). The wire is checked by
round-trip and malformed-body tests (`client/protocol_test`) and by the gateway's
authority, error-code and push tests (`client/gateway_test`). That a `propose`
call leaves no escalation record is asserted against the real store.
