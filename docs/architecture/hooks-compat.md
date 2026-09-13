# Imported hooks: the Claude compatibility matrix

An operator's existing hook collection — `~/.claude/settings.json`, a
repo's `.claude/settings.json`, a plugin's `hooks/hooks.json` — loads
into Loom and runs with nearly 1:1 behavior against the pinned
contract (`docs/design-notes/claude-hooks-contract.md`, fetched
2026-09-11). The design that fixes the shape is
`docs/design-notes/hooks-compat.md`; this document is the parity
matrix the issue asks to be published: every documented event, its
mapping, its tested rows, and its remaining gaps, plus the mechanics
that are shared across events.

## Where the code lives

| Module | What it owns |
|---|---|
| `client/hookcompat` | The unified model both accepted formats decode into: the Claude JSON shape verbatim and the native `[[hooks.Event]]` TOML. Merge, TOML render (implemented; the `loom hooks convert` command that would expose it is follow-up work), the canonical hash for the trust record, and the load-time notes. |
| `client/hookrunner` | One imported command hook as one jailed process: `sh -c` (or exec form) through `broker.clear_call`, the event JSON on stdin, per-hook timeout as the wall, exit code and both streams captured. |
| `client/hookdecisions` | Reading a finished process back as the decision the contract specifies: exit-code rules, stdout classification, per-event decision fields, `hookSpecificOutput` with its event-name guard, output capping. |
| `client/hookwire` | The event boundary: the matcher table, the payload's common fields, the Loom↔Claude tool-name mapping, and the verdict combination rules. |
| `client/hookserve` | Loading the session's sources with per-source trust, and the composed gates: `tool_gate`, `tool_feedback`, `session_context`, `compaction_note`, `stop_gate`. |
| `client/hooktrust` | The recorded, hash-pinned trust a non-managed source needs before it runs. |

## The two accepted formats

Both produce the same in-memory model, so one bus, one runner, and
one trust story serve either.

- **The Claude shape**, verbatim: the `hooks` object of a settings
  file — or a whole settings file, `hooks` key included — with event
  keys, matcher-group arrays, and handler objects exactly as Claude
  reads them. Unknown handler fields are ignored, as Claude ignores
  them; an unknown *event* or *handler type* is a worded error at
  load.
- **The Loom shape**: `[[hooks.PreToolUse]]` matcher tables with
  nested `[[hooks.PreToolUse.hooks]]` handler tables, in `loom.toml`
  or a standalone file. `hookcompat.to_toml` renders the Claude shape
  into this one, losslessly: the round-trip `parse_loom(to_toml(c))
  == c` is a tested property. No CLI exposes it yet, and
  `hookserve.locations` emits only Claude settings files, so nothing
  in a running session reads the Loom shape today.

Sources **merge, never replace**: user, project, local, plugin in the
caller's precedence order, every matching group running for the
event — Claude's own semantics.

## Matchers

Classified the way the contract classifies, at parse time: `""`,
`"*"`, or omitted matches everything; a string of letters, digits,
`_`, `-`, spaces, `,` and `|` is an exact-name list (split with
whitespace tolerance); any other character makes it an unanchored
regular expression, evaluated against the field the contract's table
names for that event. `gleam/regexp` (Erlang `re` underneath)
evaluates the expression; a malformed pattern matches nothing, which
is what the contract's own engine does with one. The load-time notes
do **not** examine matchers, so a pattern that never compiles is
silent — reporting it is follow-up work. A hyphenated matcher stays on the
exact path — the contract's v2.1.195+ behavior — so
`code-reviewer` does not fire for `senior-code-reviewer`.

## Handler kinds

| Kind | Status |
|---|---|
| `command` | **Runs.** Shell form (`sh -c`) and exec form (`args`, no shell), `async` parsed (see gaps), `timeout` seconds, `if` rules noted but not yet evaluated (see gaps). |
| `http` | Parsed, loads, **not run** — the harness's egress surface is an operator allowlist, not an open POST. |
| `mcp_tool` | Parsed, loads, **not run** yet. |
| `prompt` / `agent` | Parsed, loads, **not run**: both are a model call wearing a hook's clothes, which is a different trust surface. |

"Not run" is structural rather than incidental: `hookwire.matching_handlers`
keeps only `command` handlers, so a gate has no way to reach the other
four kinds. `hookcompat.notes` names each one at load time, and the
boot log carries those lines.

## Command execution, and the two accepted differences

A command hook runs through `broker.clear_call` — the same jailed
path the worktree observation's `git` and the `bash` tool take —
with the session workspace as `cwd`, the session environment
(`PATH`/`HOME`/`TMPDIR` plus `[tools] env` names) as its env — with
`HOME` re-pointed at the operator's own home, see below — the
event payload as stdin, and the handler's `timeout` as the wall.
Timed-out hooks are cancelled with their output discarded, per the
contract; on `PreToolUse` a timed-out hook does not block.

Two differences from Claude are accepted up front and stated here
because the issue asks for explicit explanation, not silent
shrinkage:

1. **The hook runs in the session's jail.** Claude runs hooks with
   the user's full permissions; Loom runs everything through the
   broker, and a compatibility layer that exempted hook scripts would
   be the one place in the system model-influenced text names a
   process outside the policy. A hook that reaches for a path or a
   credential the session base does not grant fails in band with
   the broker's own sentence — the visible-diagnostics story. Hooks
   that need host reach name it in the config, the same discipline
   an MCP server follows.
2. **The environment is the session environment**, not the daemon's
   inherited one: `CLAUDE_PROJECT_DIR` names the workspace, and no
   daemon secret reaches a hook's environment by default. The one name
   that is not the session's is `HOME`: a jailed tool gets a
   workspace-local home so that what a toolchain writes to `$HOME`
   stays off the operator's tree, and a hook gets the operator's real
   home instead (`serve.hook_environment`). Ten of the sixteen entries
   in the reference collection are `~/.claude/hooks/...`, so a `~` has
   to resolve where the operator keeps their scripts; it does because
   the shell expands it against `HOME`, and nothing rewrites the
   command string. Every name the hook process asks for is also granted
   on the session base (`serve.allowing_imported_hook_env`) — the
   runner's requirement is the keys of that environment, and a name the
   base withholds refuses the call rather than arriving empty.
   `CLAUDE_ENV_FILE` is **not implemented**: nothing writes a
   session-owned env file and nothing appends one to a later tool
   environment.

An `allow` decision never raises authority: every imported gate sits
*after* the harness's own clearance and can only lower, never widen.
An `updatedInput` rewrite is held to the same rule: the replacement is
put back through the harness's clearance before it runs, so the
arguments the permission tables approved and the arguments the tool
receives are the same arguments.

## The event matrix

Every event the pinned contract documents. "Mapping" names the
harness moment the event composes into; "tested" names the test
modules holding the row.

| Event | Mapping | Tested | Gap / note |
|---|---|---|---|
| `SessionStart` | Context injection at the **first** run start of a composed `Effects`, once per session; plain stdout and `additionalContext` both become model context | `hookdecisions_test`, `hookwire_test`, `hookserve_test`, `hookserve_e2e_test` | The only source that fires is `startup`. `resume` and `compact` have no moment on this path, and Loom has no `/clear` and no session *fork*, so a matcher naming any of the three matches nothing |
| `UserPromptSubmit` | Prompt admission | `hookdecisions_test` | **The gap this issue owns:** the harness has no prompt-admission seam yet. Blocking and context injection are decided and designed; the gateway slot is the remaining work. |
| `PreToolUse` | Tool clearance, after the harness's own clearance; `allow`/`deny`/`ask`/exit-2, `updatedInput` rewrite re-cleared on the rewritten arguments | `hookdecisions_test`, `hookwire_test`, `hookrunner_test`, `hookserve_test`, `hookserve_e2e_test` | `ask` rides the escalation plane; `defer` is a non-interactive-mode concept with no Loom counterpart, parsed and noted |
| `PostToolUse` | Result fold: `decision: "block"` rides beside the original result; `updatedToolOutput` rewrites the content the model reads | `hookdecisions_test`, `hookserve_e2e_test` | Replacement is narrowed to content — `is_error`, cost, and coordinates stay the harness's, the same rule the native `tool_result` fold holds. The payload carries the contract's tool fields but **not `tool_response`**: a hook that reads the call's result rather than its input finds nothing, and carrying it is follow-up work |
| `PreCompact` | The `before_compact` note appended to the summarizer's input | `hookdecisions_test` | **No veto, by existing ruling** ("a hook that could stop a compaction would not be safe"): Claude can block compaction; Loom's row says a veto needs its own protocol note against the compaction ruling |
| `Stop` | The run-end boundary: `decision: "block"` / exit 2 places the born-placed follow-up and continues the run; the 8-block override maps to a harness-side cap on the per-operation follow-up count | `hookdecisions_test`, `hookwire_test`, `hookserve_test`, `hookserve_e2e_test` | The gate composes onto the existing `run_end` slot, which is what keeps it durable under replay, and it is asked only when the harness placed no follow-up of its own. `stop_hook_active` **is carried**, derived from the same per-operation tally the cap binds on: an operation is one conversational run, so "this gate has placed a follow-up for this operation" and "a stop hook already blocked this cycle" are the same interval, and a hook that self-limits on the field stops asking exactly when the cap would have stopped asking anyway. Because an operation *is* one turn, the field resets each turn — a hook that self-limits sees one nudge per turn rather than one per session |
| `SubagentStop` | The same run-end boundary, scoped to the subagent's strand | — | Rides `Stop`'s mapping; per-strand scoping lands with the serve wiring |
| `Notification` | — | — | No TUI notification moment exists; entries load, `once`/`terminalSequence` noted |
| `PermissionRequest` | — | — | The escalation seam exists (`client/escalate`); the wiring is the remaining work, recorded here rather than guessed |
| `MessageDisplay`, `TeammateIdle`, `ConfigChange`, `CwdChanged`, `DirectoryAdded`, `FileChanged`, `InstructionsLoaded`, `PostCompact`, `PreModelSwitch`, `PostModelSwitch`, `SubagentStart`, `TaskCreated`, `TaskCompleted`, `StopFailure`, `Setup`, `Elicitation`, `ElicitationResult`, `UserPromptExpansion`, `PostToolUseFailure`, `PostToolBatch`, `PermissionDenied`, `SessionEnd`, `WorktreeCreate`, `WorktreeRemove` | — | — | No harness moment; entries load without edits and the load-time notes name each one once, rather than refusing the collection or faking a fire |

The "declared-and-skipped" middle is deliberate: the issue's
acceptance is loading a collection **without editing it**, and a
collection carrying a `MessageDisplay` hook must load as much as one
without it — while the operator sees, at load time, which entries
will never fire and why.

## What is verified where

Four layers, and each answers a different kind of question.

**`hookdecisions_test`** pins the contract's output rules against the
fixture files in `docs/fixtures/hooks-compat/decisions/`: the exit-code
table, the `hookSpecificOutput` shapes, plain stdout as context, and the
discarded output of a timed-out or clipped run. No process runs.

**`hookcompat_test`** pins the parse: both accepted formats decoding to
one model, matcher classification, the merge, the TOML round trip, the
trust hash, and the reference collection in
`docs/fixtures/hooks-compat/owner-collection.json` — sixteen handlers
across ten events — parsing with no edit of any kind.

**`hookrunner_test`** and **`hookserve_test`** run real jailed processes
through the real broker: a `~` resolving to the operator's home, a
script under it executing by tilde path, a name outside the base
allowlist refusing the call before any process exists, and the composed
gates' decisions over a broker that counts what each gate asked for.

**`hookserve_e2e_test`** is the acceptance case of issue #350. One real
session assembled by `serve.open_instance`, an unedited user-level
collection under a temporary `Settings.home`, and `SessionStart`,
`PreToolUse`, `PostToolUse` and `Stop` all firing at their own harness
moments across a single operation — one a `Stop` block holds open and a
second `Stop` ask lets finish. The injected context and the block's
follow-up are asserted in the provider request bodies, because that is
where a message that was never sent could not appear.

The last three need the host's jailed executor and so do not run inside
a nested sandbox. None of them is driven by hand. The acceptance proof
was briefly a shell script an operator was meant to run in two steps
around a session they drove themselves; nothing ever ran it, and three
of its steps were wrong from the first commit. A test under
`make check-client` fails as soon as it stops being true, which is the
whole difference.

## Code mode: the boundary

A direct tool call fires the tool events through the clearance gate.
The same operation invoked through code mode is a `cap_call` at the
broker and is **not** a tool event: firing both would double-charge
one operation, and firing only the direct path would let code mode
bypass every gate — so the seam is stated rather than guessed.
Imported tool hooks cover the model's tool surface; code-mode
capability calls carry their own vetting (the seam allowlists), and
extending imported `PreToolUse` into the capability router is
follow-up work with its own trust questions, not a gap in this
matrix. This is the one place "nearly 1:1" spends its budget on
semantics, and the issue's acceptance — "document the exact event
boundary and avoid duplicate invocation" — is the row's citation.

## Trust

Non-managed hook sources need explicit trust before they run,
recorded against the **hash of the current definition**
(`client/hooktrust`): a changed file re-enters review and is skipped
with a logged line until re-trusted. The operator's own user-level
settings file is trusted on **first** sight — it is the operator's
file on the operator's machine, the same trust it carries in Claude —
and re-enters review like any other source once its hooks change. A
project file arrives with the repository and asks first, the same
posture the extension install record takes. A server with no home
directory has nowhere to keep a record, so it trusts nothing.

The pin covers the **declaration**, not the scripts it names. A
trusted `command: "./scripts/pre.sh"` keeps its hash while the bytes
of `pre.sh` change underneath it, and inside a workspace the model's
own `fs_write` is one of the things that can change them. Pinning
script contents would mean resolving and hashing an argv the shell has
not expanded yet; this build does not attempt it, and an operator
trusting a project source is trusting its scripts too.

`loom hooks` (list, trust, revoke, convert) is the intended CLI
surface and **does not exist in the tree**. Until it does, the
user-level file trusted on first sight is the only source that can
serve; recording trust for a project, local or plugin source is
follow-up work.
