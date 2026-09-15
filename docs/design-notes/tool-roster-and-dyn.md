# Design note: the tool roster, and what `dyn` taught us

Status: **note; implemented on branch `explore/tool-roster-code-mode`.**
The work this note argues for is in the tree: a `[tools] roster` setting,
a `loom --tools` launcher flag with `protocol-change/039` behind it, the
`cap://` and `job://` schemes on `fs_read`, a shrunken `code_mode`
description, and two new capability modules. Every byte figure below was
measured against the shipped allowlists rather than estimated, and the
test that pins the largest of them is named where it appears.

This note answers one question: given that a large tool roster is
measurably expensive, what does a harness do about it? The oh-my-pi
playbook and its `omp2` branch answer with a fixed tiny roster plus a
dispatcher built into the shell. Loom answers with a fixed tiny roster
plus code mode and an on-demand read. The two answers are close enough
that the differences are worth writing down.

## What the playbook measured

`docs/design-notes/harness-playbook.md` is the full reading of Can
Bölük's *The Harness Playbook* (2026-09-02) against Loom. Its chapter 6
carries the measurement that started this work: under grammar-constrained
sampling, a 23-definition tool roster cost nearly twice the wall-clock of
a 5-tool one on the same task. The cost is not the model calling more
tools. It is the definitions themselves, which are in the request before
the first token of the system prompt and are re-read on every request of
every strand for the life of the session.

The playbook's conclusion is that the permanent grammar should be small
and stable, and the long tail should sit behind one stable surface that
the model reaches into when it needs to.

## What `dyn` is

The `omp2` branch acts on that conclusion with a shell builtin,
`dyn`, in `crates/shell-builtins/src/dyn.rs`, decided in that
repository's ADR 0024 and ADR 0025. It does three things. It lists a live
catalog of everything the harness can do, so the model discovers a
capability without a definition for it being resident. It synthesizes a
`--help` page for any entry from that entry's JSON schema, so the model
reads an argument list on demand. And it dispatches the call, so the
catalog entry is reachable without ever becoming a wire tool.

At the `omp2` head the wire-slot set is five names, `read`, `edit`,
`grep`, `glob` and `bash`, with `write` and `eval` demoted to devices
reached through those rather than slots of their own. Everything else,
including the whole MCP surface, is behind `dyn`.

The shape is worth naming precisely, because Loom's answer is the same
shape with different parts: a small fixed roster, a discovery index, a
`--help` for one entry, and a dispatcher.

## What Loom's roster costs

Loom's own numbers, measured on the wire as name plus description plus
JSON schema, against the allowlists the tree actually ships.

The whole registry, before this change and with the description as it
then rendered:

| Registry | Tools | Wire bytes |
| --- | --- | --- |
| Full roster | 21 | 65,885 |
| The five core tools alone | 5 | 4,463 |

Those two rows were measured with a throwaway module that built every
built-in tool against stub seams and summed the three fields; only the
`code_mode` figures below are pinned by a checked-in test.

So the five tools a session cannot work without were about seven percent
of what a full roster put in front of the model on every request. The
single largest entry was `code_mode`, because its description carried the
whole public surface of every prelude module the host's seams admit.
`code_mode` alone, before and after the description shrank:

| Host | Before | After |
| --- | --- | --- |
| Workspace seam only | 52,162 | 25,690 |
| Orchestration seam only | 17,753 | 10,698 |
| Both seams | 64,842 | 33,472 |

`the_workspace_description_stays_under_its_bound_test` in
`packages/tools/test/tools/codemode_test.gleam` pins the first of those
at 28,000 bytes, which is the measurement with about a tenth of headroom.
The bound exists so the next increase is a decision somebody took and
wrote down rather than a drift nobody noticed.

## The decisions

### The roster is an operator setting, and a per-session one

`[tools] roster = "minimal" | "full"` in `loom.toml`, parsed into
`catalog.Roster` and defaulting to `Full`. `contributions.built_in_for`
takes it and builds the registry from it.

Plane gating was already there and is the wrong instrument. An `Option`
per plane answers whether this host *has* a thing. It cannot answer
whether this deployment wants to *pay* for the thing, because the price
is not paid by the plane: it is paid by the cached prefix of every
request of every strand, whether the tool is ever called or not.

The daemon-wide setting is also the wrong granularity on its own. One
terminal wants a small registry for a cheap model on a narrow task while
another, against the same daemon, wants everything. So the choice also
travels per session, as an optional `roster` field on `sessions.create`
(`protocol-change/039`), set from `loom --tools minimal|full`. It is
creation metadata, not a view setting: a session's registry is built
during assembly, before the first turn, and the available-tools index in
the system prompt is rendered from that registry and then pinned.
Anything arriving later is narrowing something already built and paid
for. The word persists on the registration (`catalogue_sessions.roster`,
catalogue schema v4) and `serve.resolve_managed` applies it over the
daemon's default on every rebuild, so a restarted daemon serves the same
registry to the same session.

### `Minimal` is six tools

`bash`, `grep`, `fs_read`, `fs_write`, `fs_edit`, and `code_mode` where
the host opened that plane. The six `agent_*`, the three `job_*`, the
three `schedule_*`, `history_search`, `remember` and `context_remaining`
are not registered, even where their plane is open and wired.

`bash` keeps its jobs door under both rosters. The door is what makes
`mode: "background"` answerable, so taking it away would change what a
core tool does rather than how many definitions the prefix carries.

### Code mode is the only other door, and that is the point

Everything `Minimal` drops is reachable from a code-mode program, so the
roster narrows the door rather than the ability. A session on `Minimal`
still spawns agents, starts background jobs, writes schedules, searches
history and writes notes. It writes a program to do it, and the program
is checked by exactly the same vetting policy and reaches exactly the
same seams a wire call would have reached.

That claim only holds if the seams are actually served, and one of them
is not served by default. `cap/strand` lives on the orchestration seam,
which a shipped server offers only when `--codemode-seams` names
`orchestration` or `both`; the flag's own default is the workspace seam
alone. So `Minimal` makes the orchestration seam part of the roster
rather than a separate choice: when the roster is `Minimal` and
`--codemode-seams` was not named, the server serves both seams, because
a session with no `agent_*` tools and no orchestration seam could not
spawn an agent at all. An operator who names `--codemode-seams`
explicitly keeps exactly what they named, `Minimal` included, and a
session on that server reaches whatever those seams admit.

Three of those doors already existed: `cap/strand` is the orchestration
seam's spawn, join and address surface, `cap/job` is the background-job
surface, and `cap/schedule` writes heartbeats. Two are new on this
branch, both on the workspace seam:

- **`cap/history`** (`search`, `search_for`, `read`), which mirrors
  `tools/history`'s `Scope`, `Hit` and limit clamp.
- **`cap/memory`** (`remember`), write-only, with no read call by design.

Their host arm is `codemode/recall.gleam`: one `Recall(index:, store:)`
record holding the very seams the `history_search` and `remember` tools
are built over, a `serviced_caps` list read per host, and a `routing`
arm stacked into `client/codemode.workspace_router`. A query issued from
a program therefore runs over one index with one set of bounds and comes
back with the refusals the tool call would have met. Both halves are
optional and a `None` leaves the capabilities unrouted rather than routed
to a closure that can only refuse, which is `cap/schedule`'s posture: a
program that cannot reach recall carries on.

A third module, **`cap/context`** (`report()`, returning the window,
the tokens used, the compaction boundary and the note count, mirroring
`tools/context`'s `Report`), lands on the same workspace seam and the
same recall arm. It is the programmatic answer to the one tool `Minimal`
drops that had no twin.

Both new modules are on `default_cap_modules()` only. The orchestration
seam still shares exactly `cap/report` with the workspace seam, and the
intersection test is what holds it there. The argument is the one the
seam split has always made: an orchestrator that could also read every
session this repository has ever had, or mint a note that reaches every
later session as quoted context, is a materially worse thing to hand a
model than one that cannot.

### `cap://` is the `--help`

The `code_mode` description used to paste every admitted module's whole
public surface. It now carries, per seam section, an index line and the
module's `pub type` declarations, and nothing else. `scripts/gen-prelude.py`
emits a second constant, `tools/prelude.type_surfaces`, which is each
module's block cut after the types, character for character a prefix of
its `surfaces` counterpart. An MCP façade gets only its index line,
because a `cap/mcp/<server>` block is one host's server rendered whole and
has no separable type section to keep.

What left the description is read back through a scheme on `fs_read`.
`cap://<module>` returns that module's full rendered block from
`prelude.surfaces`, or a seam's `extra_surfaces` façade found by its
`### cap/mcp/<segment>` heading, filtered by the offered seams'
`allowed_imports`; `cap://` alone is the index. The filter direction is
the security-relevant one: a module vetting will reject must not be
readable here, or the model writes against something it cannot import and
reads a refusal it has no way to understand.

Two things make the omission survivable rather than a regression. The
legend says in one sentence that signatures are not shown and where to
read them, so a model that would otherwise guess reads instead. And the
types stay: `proc.run` returns a `proc.Output`, and a program that cannot
name the `stdout` field cannot read the output it just paid for, so a
guessed field name costs a compile round trip either way.

`job://` is the same mechanism spending the same sentence: `job://<id>`
is a zero-wait poll of one job rendered by `job_poll`'s own
`render_polled`, and `job://` alone is the listing. It is what lets
`Minimal` drop `job_poll` without dropping the ability to look at a job.
A scheme read renders plain, with no digest and no anchors, because
nothing edits it, and it stays `replay: Safe` because it carries no
cursor and advances nothing.

### The per-request context footer was considered and rejected

`context_remaining` is the one drop whose content is a number the harness
already holds, so a footer rendering that number onto the newest tool
result at request-build time looked like a free replacement. It was
rejected on three counts. It duplicated the near-limit reminder
(`wiring.near_limit_reminder`, `checkpoint.reminder`), which already
fires when the number starts to matter. It cost a cache write per turn,
because a footer that changes every request changes the bytes the
provider had cached. And it is harness commentary inside tool output,
which is the thing gap 3 of the playbook note argues against: a program
composing tool output through `cap/proc` cannot rely on the output when a
notice may be inside it.

So the reminder remains the one signal, and `cap/context` is the
programmatic read.

### A jailed `cap` CLI was considered and rejected

The closest port of `dyn` would have been a jailed command, reachable
from `bash`, that lists capabilities, prints a schema and dispatches a
call. It was rejected because it would give `bash` a second dispatch path
onto MCP servers and onto strand spawn. Today those are reached only by a
vetted program over the capability channel, where the module a program
imports is the unit of authorization and the vetting theorem is that a
program's capability set is computable from its source. A CLI in the jail
answers to a shell string instead, and the whole seam confinement would
have to be re-argued against an argument vector.

Code mode is Loom's `dyn`, and it was already there. What was missing was
the `--help`, which is what `cap://` is.

## What is deliberately open

**The default roster.** `default_tools()` returns `Full`, and the
decision to move it is a measurement rather than an opinion: drive the
same tasks on both rosters against GLM and Kimi via Baseten, and against
Anthropic, and compare wall-clock and drive quality. Until that says
otherwise a session registers what it has always registered.

**What inherit means across a flip.** A session created with `--tools`
stores that word and gets the same registry back on every rebuild. A
session created without one stores nothing and follows the daemon's
`[tools] roster` at each boot, and the rest of the session does not
follow with it: the system prompt is pinned once and keyed only on the
enforcement demand, and `strand.config`'s `active_tool_names` is seeded
once at the first boot. So an operator who flips the daemon's default
and restarts should expect existing inherit sessions to rebuild a
different registry than their pinned prompt describes, with the prompt's
available-tools index naming tools that are no longer on the wire,
`wiring.tool_specs` dropping them at render and `wiring.clear` refusing
a call on one, until each such session is replaced by a new one. This is
the same class of behaviour `LOOM_DISABLE_TOOLS` has today, and it is
documented rather than mechanised. Binding the resolved roster into the
prompt pin's identity alongside the enforcement demand is the fix if it
ever matters.

**`cap/context` on the orchestration seam.** It is on the workspace seam
only. Whether an orchestration program should be able to read its own
context state is a real question and is not answered here.

**The extension bridge asymmetry.** `policy.extension_cap_modules` is the
workspace seam widened, so `cap/history` and `cap/memory` are admissible
to an installed extension by construction. The bridge an extension
dispatch builds (`client/extension/dispatch`) composes no recall arm, so
such a program compiles, is admitted, and meets `unsupported_cap`. That
is deliberate and documented at
`packages/client/test/client/extension/freeze_test.gleam`: an
extension's reach is fixed at install rather than by a per-host probe,
and widening the bridge is a decision with its own record to write.

**Code mode's per-call floor.** A program pays a hermetic build and a
satellite launch. For a one-shot bounded call, such as reading one job's
state or writing one note, that floor is larger than the wire tool it
replaces, which is exactly why `job://` and `cap://` exist as reads. The
levers that would lower the floor for everything else are the kept-alive
satellite cell and the compile cache, both already described in
`docs/architecture/code-mode.md`. Neither is scheduled by this work.

**Index-only versus index-plus-types.** The cut is currently after the
`pub type` declarations. Dropping the types too would roughly halve the
remaining figure again, and the argument against it, that a guessed field
name costs a compile either way, is a claim about model behaviour that a
drive could check rather than a fact that has been measured.

**The remaining schemes.** `history://`, `agent://` and an artifact
scheme are still open from issue #192. `fs_read` now has the resolver
they would register into.
