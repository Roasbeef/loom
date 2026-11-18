# protocol-change/119: the `ask` and `notice` tools and their records

**Status**: ACCEPTED 2026-11-18. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. Not built.
**Affects**: two new built-in tools (`ask`, `notice`); two new reserved
`fact.custom` prefixes in the session store (`attention/ask/`,
`attention/find/`); one new capability module (`cap/attention`) with its
code-mode door; the default system prompt (one sentence and a version bump).
No client command, wire frame, event or `loom.toml` key changes. The
read side of the records (the feed, its snapshot and its scope) is
protocol-change/120, and the send that carries an answer is
[118](118-inbox-thread-send.md).
**Raised by**: phase 1 of the attention inbox
(`docs/design-notes/attention-inbox/README.md`, sections 3 and 4).
**Builds on**: [045](045-code-mode-notes.md) (a capability that shares the
host closure of a tool), [086](086-memory-proposals.md) (a tool that files a
durable record and never blocks), [106](106-project-mode.md)
(`project_report`) and [118](118-inbox-thread-send.md) (a person's message to
a session from Home). **Implemented**: not yet. Expected: `tools/ask`,
`tools/notice`, `client/attention`, `client/contributions`, `client/serve`,
`client/codemode`, `client/cap_placement`, `runtime/api`, `cap/attention`,
`codemode/attention`, `codemode/tool_gate`, `codemode/vet/policy`,
`tools/prelude`, `prompt/default`.

## Problem

A model that needs a decision from the owner has one door today: it writes the
question as prose at the end of its turn. The page showing the owner's
sessions cannot tell that question from any other final message, cannot offer
options, and receives the answer as free text the model must parse. A model
that notices a risk, a bug or an idea outside its task has no door at all; the
observation is lost unless it happens to be in the transcript where a person
reads it.

The attention inbox (`docs/design-notes/attention-inbox/README.md`, section 4,
phase 1) needs both as records: a question with a typed answer, and a find
that is shown beside the code it concerns. This document defines the two tools
that write the records, the records, the way an answer reaches the strand, and
what that costs. It does not define how a client reads the records.

## What was considered

### A blocking ask

`ask` could park the call until a person answers, as a refused call does. This
is rejected. The escalation's wait is `park` (`client/escalate.gleam`, `park`),
which polls the record for `park_timeout_ms`, 5000 ms
(`client/escalate.gleam`, `park_timeout_ms: 5000`), and then detaches the call
through `detach_or_spend` (`client/escalate.gleam`, `detach_or_spend`). A
person's answer to a question can take hours. A call held open that long keeps
a tool effect process and the call's budget deadline alive, and a detached
escalation answers with a notice that tells the model to run the call again,
not with a value.

### Reusing `project_report`'s question

A project worker's `project_report` carries one optional `question` string
beside `status: waiting` (`tools/project.gleam`, `report_tool`). It has no
options, no typed answer and a 500-character bound. It stays as it is for a
ticket's question. Project workers do not get `ask`, so a ticket's question
has one path (see "Who gets the tools").

### Records in the memory store

Proposals live in the domain's memory store, shared by every session of a
domain ([086](086-memory-proposals.md), "The proposal"). An ask or a find
belongs to one session, one strand and one transcript position, so it is kept
in the session store, as escalations are (`escalation/<id>`), and is removed
with the session.

### A model-writable blackboard cell

`agent_note` writes `agent/<strand>/<key>`, readable by every strand
(`tools/agent.gleam`, `note_tool`). A model could then forge or edit a record
a person is about to act on, including an answer. Reserved prefixes close that:
`api.put_fact` refuses them (`runtime/api.gleam`, `put_fact`, which calls
`reserved_fact_key` at its first `case`).

## Decision

### The `ask` tool

`ask` puts up to four questions to the owner, or to a named strand. It records
the ask and returns at once. It does not wait for the answer.

| Argument | Type | Bound |
|---|---|---|
| `questions` | array of question | 1 to 4 entries. Required. |
| `to` | string | A strand name of this session. Optional. Absent means the owner. |
| `why` | string | At most 200 characters. Optional. |

Each question has these fields.

| Field | Type | Bound |
|---|---|---|
| `prompt` | string | At most 300 characters. Required. |
| `kind` | string | One of `confirm`, `choice`, `multiple`, `checklist`, `fill`. Required. |
| `options` | array of option | 2 to 8 entries. Required for `choice`, `multiple` and `checklist`; refused for the others. |
| `min`, `max` | integers | `multiple` only. `0 <= min <= max <= number of options`. Optional; the defaults are 1 and the option count. |
| `format` | string | `fill` only. One of `text`, `long_text`, `path`, `number`, `url`. Optional; the default is `text`. |

Each option has these fields.

| Field | Type | Bound |
|---|---|---|
| `label` | string | At most 60 characters. Required. Unique within the question. |
| `note` | string | At most 140 characters. Optional. Says what choosing the option does. |
| `recommended` | boolean | At most one option per question has it. |

The kinds are the closed set the page draws with fixed components. They mean
the following.

| Kind | The person gives | The answer value |
|---|---|---|
| `confirm` | yes or no | `true` or `false` |
| `choice` | one of the options | the chosen option's label, a string |
| `multiple` | between `min` and `max` of the options | a list of labels |
| `checklist` | any subset of the items, possibly none | a list of labels |
| `fill` | text of the stated `format` | a string. A `number` is carried as the string the person typed, after the page checked that it parses. |

Every question also accepts "Other", answered as free text. A question
answered by Other has the value `null`, and its text is carried beside it (see
"The answer"). `confirm`, `choice`, `multiple` and `checklist` options are
labels and notes only: the page draws them as text, and no argument carries
markup.

An ask MUST NOT request a secret. The tool's description MUST say so and MUST
say that credentials go through grants and approvals. The page MUST NOT draw a
password field for any kind, and no `fill` format names one. This is a rule on
what the model is told and what the page can draw. The tool cannot determine
whether a prompt's words ask for a secret, and this document does not claim it
can.

The host assigns each question the key `q1` to `q4` by position. The model
supplies no question identifiers.

`ask` refuses in band, as a tool failure the model reads, when an argument is
out of bound or of the wrong shape, when `to` names no strand of the session,
or when 32 asks are open in the session (see "The records"). It returns
`asked as <id>` and `with_details({id})`.

`replay` is `Never`: a replay would record the ask twice.
`execution_mode` is `Exclusive` (`tools/tool.gleam`, `ExecutionMode`, whose
`Exclusive` variant "must run alone"). Exclusivity is also what lets the call
end the run, as the next paragraph requires.

The tool returns `ToolOutcome.terminate: TerminateRun` on success
(`tools/tool.gleam`, `Terminate`), so the run reaches a terminal state once
the batch settles. The planner ends a run only if every call in the batch
terminates (`tools/tool.gleam`, `TerminateRun`), and `Exclusive` guarantees the
batch holds this call alone. A refused call returns `ContinueRun`, so the model
can correct its arguments. The same shape exists for the project judge's tools
(`client/project_judge_session.gleam`, `ending`). `project_report` is not an
example: its worker ends its own turn after `recorded.`, and nothing in the
tool terminates the run. The strand is then idle with an open ask.

### The `notice` tool

`notice` records something the agent saw outside its task. It does not stop
work.

| Argument | Type | Bound |
|---|---|---|
| `kind` | string | One of `risk`, `idea`, `bug`, `question`. Required. |
| `text` | string | At most 300 characters. Required. |
| `path` | string | Workspace-relative. Optional. Refused if absolute or containing `..`. |
| `line` | integer | Positive. Optional. Accepted only with `path`. |

It returns `noted as <id>` with `with_details({id})` and continues the run
(`ContinueRun`). `replay` is `Never` and `execution_mode` is `Concurrent`: two finds in one
batch may run together, and the bound is checked inside the commit that writes
the record (see "The records"). It refuses in band when 128 finds are open.

A find is closed by a person, as fixed, filed or dismissed. The agent has no
tool that closes or edits one. `question` is a find kind for something the
agent wonders about and will not stop to ask; a question that needs an answer
before work continues is an `ask`.

### The records

Both are reserved `fact.custom` registers in the session store, as
escalations (`escalation/<id>`) and glances (`client/glance/<strand>`) are.

| Prefix | Key | Content |
|---|---|---|
| `attention/ask/` | `attention/ask/<id>` | one ask |
| `attention/find/` | `attention/find/<id>` | one find |

`<id>` is `ask-` or `find-` followed by ten lower-case hexadecimal digits.

Both prefixes MUST be added to `api.reserved_fact_key`
(`runtime/api.gleam`, `reserved_fact_key`), which lists every reserved prefix
and is what `put_fact` consults. Until they are, a model could write under
them with `api.put_fact`. The host writes them with `api.put_reserved_fact`
(`runtime/api.gleam`, `put_reserved_fact`), which refuses a key outside the
reserved set, so a record can be written only by host code.

Each record carries these fields.

| Field | Meaning |
|---|---|
| `id` | As above. Repeated in the payload so a scan needs no key parsing. |
| `kind` | `ask` or `find`. For a find, the find kind is `find_kind`. |
| `created_at` | Unix time in milliseconds, read with `clock.read` on the call's clock (`core/clock.gleam`, `read`). It MUST NOT be seeded from monotonic time, which is negative on the BEAM. |
| `routing` | `owner`, or the name of the strand `to` named. A find is always `owner`. |
| `anchor` | The call's durable coordinates: operation id, step id and source index, from `tools/tool.gleam`, `Ctx`. They are the driver's own values, never the model's. The reader resolves them to a transcript position. |
| `strand` | The strand that made the call, from the same `Ctx`. |
| `parents` | The strand's parent chain, nearest first, from the lineage cells (`runtime/lineage.gleam`, `Lineage`, whose `parent` field is the spawning strand). Empty for `main`. |
| `status` | `open`, `answered` or `closed`. An ask is `open` then `answered`. A find is `open` then `closed`. An ask is never `closed`. |
| `content` | The ask's `why` and questions, or the find's text, `path` and `line`, as validated above. |
| `answer` | Present when `status` is `answered`: the answer object and the answerer's identity. |
| `settled_at` | Present when `status` is not `open`. Unix milliseconds. |
| `closure` | Present on a closed find: `fixed`, `filed` or `dismissed`, and the person who closed it. |

Bounds. A session has at most 32 open asks and at most 128 open finds. A call
past the bound is refused in band with words saying which bound and its value.
The count is the number of records with `status` `open` under the prefix, read
inside the same commit that writes the new one, so two concurrent calls cannot
both take the last slot. A cell that cannot be decoded is left out of every
count and every listing, as a damaged proposal is.

Settled records are removed when they are 7 days old or when more than 200
settled records of that prefix exist, whichever removes more, oldest first. The
removal is part of the commit that records the settlement, as
[086](086-memory-proposals.md) retires decided proposals
(`client/proposals.gleam`, `retired_ids`, called from `settle`). Proposals are
pruned by count only (`client/proposals.gleam`, `max_listed`); the age limit is
new here. An open record is never removed by pruning.

Reading these records, listing them and notifying a client that one changed are
the feed's, in protocol-change/120. This document adds no command, snapshot or
event.

### The answer

A person answers through the Home page's thread send ([118](118-inbox-thread-send.md)).
The answer reaches the asking strand as an ordinary prompt, so the transcript
records who sent it and the model reads a typed value instead of prose. The
prompt text is a sentence naming the ask followed by one fenced JSON object:

```json
{
  "ask": "ask-3f9c01a2b4",
  "answers": { "q1": true, "q2": "Retry", "q3": ["a.gleam", "b.gleam"], "q4": null },
  "other": { "q4": "Do it in a branch instead." }
}
```

`answers` has one key per question. Its value is the kind's answer value from
the table above, or `null` when the question was answered by Other. `other`
has a key only for a question answered by Other, and its value is the person's
text. The host builds the object from the page's submission, validated against
the stored record: a key must name a question of the ask, a label must be one
of that question's options, `multiple` must respect `min` and `max`, and a
`fill` must satisfy its `format`. An answer that fails validation is refused to
the page and nothing is sent.

The host sets the record to `answered` and stores the answer and the answerer
when it accepts the prompt. If the gateway refuses the prompt, for instance
because the strand's input queue is full, the record stays `open`. If the
daemon stops between the gateway's acceptance and the record's update, the
strand holds the answer and the record is still `open`; a second answer is
accepted and the later one stands. An answer is at least once, and the
prompt in the transcript is the authoritative copy.

[118](118-inbox-thread-send.md) addresses only `main` in phase 0. An ask made
by another strand needs the send to name that strand, and this document does
not define that; protocol-change/120 extends the send. Until then an ask from a
sub-agent can be recorded and shown, and answering it is not available.

Answering is admitted to the principals [118](118-inbox-thread-send.md) admits to
send, which is the owner at the Operator ceiling. A member and an observer can
be shown asks and finds by the feed and can answer nothing.

### Code mode

Both tools are also capabilities of a new module, `cap/attention`:
`attention.ask` and `attention.notice`. A program calls them as a model's own
call does, and the wire arguments are the tool's arguments.

The door in `codemode/attention` takes the same host closures as the tools,
as `notes.put` shares `agent_note`'s closure. `client/codemode.gleam` builds
`notes.Door(put: agency.note, scan: agency.notes)` from the same `Agency` that
registers `note_tool` (`client/codemode.gleam`, `notes.Door(put: agency.note`).
The attention door is built from the closures passed to `ask.tool` and
`notice.tool`, so the validation, the bound checks and the record writes have
one implementation.

The change touches these places, each of which must agree.

| Place | Change |
|---|---|
| `cap/attention` | New module with `ask` and `notice`. Each calls `dispatch.call` with the capability name and the tool's arguments, as `cap/notes` does. |
| `codemode/attention` | New door, with `serviced_caps = ["attention.ask", "attention.notice"]` and per-execution ceilings, the way `codemode/notes` declares its. The caller's identity is the admitted one, never from the payload. |
| `codemode/tool_gate.gleam` | `required_tool` maps `"attention.ask"` to `Some("ask")` and `"attention.notice"` to `Some("notice")` (`codemode/tool_gate.gleam`, `required_tool`, beside `"notes.put"`). A strand without the tool cannot use the capability. |
| `codemode/vet/policy.gleam` | `cap/attention` is added to the program allowlist (`codemode/vet/policy.gleam`, `program_cap_modules`). |
| `client/cap_placement.gleam` | `attention.serviced_caps` is added to `owner_caps` (`client/cap_placement.gleam`, `owner_caps`), so the owner's side answers them and the workspace does not. |
| `client/codemode.gleam` | The door is installed per seam where the notes door is. |
| `tools/prelude.gleam` | Regenerated with `make gen-prelude`. `make prelude-check` fails until it is. |

An `ask` from a program does not end the turn. The capability records the
ask and returns its id to the program, and the `code_mode` call's outcome stays
`ContinueRun`, as it is for every outcome today (`tools/codemode.gleam`,
`bounded`). Making `code_mode` end the run when one inner call asked was
considered and rejected: it would change the termination of every program for
one capability, and a program may record an ask and still have work to finish
in the same execution. The capability's description says that the model ends
its turn after the program returns, so the strand is then idle with an open
ask, as it is after the tool. A `notice` from a program never ends anything.

### Who gets the tools

Every session's strands get both tools, registered as a built-in contribution,
as `proposal_tools` is (`client/contributions.gleam`, `proposal_tools`, wired
in `client/serve.gleam` where `contributions.proposal_tools(` is called). A
separate contribution leaves the order of every other tool unchanged.

Two roles differ.

- The project router's tool set is fixed at three and is built by replacing the
  contributions (`client/serve.gleam`, `project_shaped`, whose `Router` arm
  returns only `project_tools.router_tools`). The router therefore gets neither
  tool and nothing needs to change.
- A project worker keeps `project_report` for its ticket's question and does
  not get `ask`. Today the `Worker` arm removes the peer tools and the `agent_`
  names the ceiling refuses, and nothing else (`client/serve.gleam`,
  `project_shaped`; `client/project_jail.gleam`, `worker_tools`, whose refused
  prefixes are `agent_` and `peer_`). `ask` would reach a worker unless it is
  named. The worker's refused names MUST include `ask`, in `project_shaped` and in
  the ceiling that an operator's activation cannot lift
  (`client/project_standing.gleam`, `worker_excludes`). A worker keeps `notice`.

### The prompt

The default prompt's conduct section says "ask one specific question instead of
guessing at length" (`prompt/default.gleam`, the `conduct` section). It gains
one sentence after it:

> When a decision belongs to the owner, ask with `ask` and give options,
> rather than asking in prose.

The pack's version line, `%% version loom-default-17` (`prompt/default.gleam`),
becomes `loom-default-18`. A session's prompt is pinned for its life, so
running sessions keep the old text and only sessions opened after the release
carry the sentence.

## What it costs

- The tool array is the provider's cached prefix. Two tools added to it, and a
  new prompt version, change the prefix once, for every session, at the first
  release that carries them, as [086](086-memory-proposals.md) recorded for
  `propose`.
- Two reserved prefixes. Each `ask` and `notice` call counts the open records
  of its prefix, a scan of at most 32 asks plus the settled ones, or 128 finds
  plus the settled ones, and settled records are bounded at 200 per prefix, so a
  scan reads at most 232 and 328 cells.
- One capability module, one door and one prelude regeneration. The
  `code_mode` description grows by two capabilities.
- An ask ends the run, so a model that asks gets no further output in that
  operation. The strand resumes only when a person answers or sends a message.
  A model that would have continued on another part of its task does not.
- A model can fill the bounds. A full ask list refuses the next ask in band,
  and the person must answer or the 7-day pruning must remove an answered one.
  An open ask is never pruned, so 32 unanswered asks stay until answered.
- Asks and finds are model-written text. They are shown as text and only as
  text, and the page draws each question from the closed set of kinds.
- A sub-agent's ask cannot be answered until the send can name its strand (see
  "The answer").

## Verification

Each item is a test over the real store or the real function, not a fake of
either.

- `tools/test/tools/ask_test` and `tools/test/tools/notice_test`: every bound in
  the tables above, each refusal worded, `TerminateRun` on success and
  `ContinueRun` on refusal, the secret statement present in the description,
  `replay` and `execution_mode`, and that no schema field accepts markup or a
  question identifier.
- `client/test/client/attention_test`: record encode and decode round trips, a
  damaged cell left out, the open bound of 32 and 128 refused in band, two
  concurrent submissions not both taking the last slot, pruning by age and by
  count with an open record never pruned, and a record surviving a session
  restart.
- `runtime/test/runtime/api_test`: `reserved_fact_key` is true for both prefixes
  and `put_fact` refuses them.
- `client/test/client/contributions_test` and `project_standing_test`: both
  tools are registered after `propose`, the registry order of every other tool
  is unchanged, a project router has neither, and a project worker has `notice`
  and no `ask`, including after an operator activation.
- `codemode/test/codemode/tool_gate_test`: `required_tool("attention.ask")` is
  `Some("ask")` and `required_tool("attention.notice")` is `Some("notice")`, and
  a strand without the tool is refused the capability. `client/test/client/cap_placement_test`:
  both capabilities are owner caps.
- `client/test/client/owner_codemode_test`: a program's `attention.ask` records
  the ask and returns its id, the `code_mode` outcome stays `ContinueRun`, and a
  `notice` records a find the same way.
- `make prelude-check`: the prelude digest matches and `cap/attention` is on a
  seam allowlist.
- `prompt/test/prompt/default_test`: the conduct section carries the sentence,
  the version is `loom-default-18`, and the constant sections hold no
  placeholders.
- The answer object: `client/test/client` tests that a submission is validated
  against the stored record, that a refused prompt leaves the record `open`, and
  that the fenced object round trips to the types in the table.
