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
| `client/hookcompat` | The unified model both accepted formats decode into: the Claude JSON shape verbatim and the native `[[hooks.Event]]` TOML. Merge, TOML render (for `loom hooks convert`), the canonical hash for the trust record, and the load-time notes. |
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
  or a standalone file. `loom hooks convert` renders the Claude shape
  into this one, losslessly: the round-trip `parse_loom(to_toml(c))
  == c` is a tested property.

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
evaluates the expression; a malformed pattern matches nothing and
the load-time notes name the file. A hyphenated matcher stays on the
exact path — the contract's v2.1.195+ behavior — so
`code-reviewer` does not fire for `senior-code-reviewer`.

## Handler kinds

| Kind | Status |
|---|---|
| `command` | **Runs.** Shell form (`sh -c`) and exec form (`args`, no shell), `async` parsed (see gaps), `timeout` seconds, `if` rules noted but not yet evaluated (see gaps). |
| `http` | Parsed, loads, **not run** — the matrix row says so; the harness's egress surface is an operator allowlist, not an open POST. |
| `mcp_tool` | Parsed, loads, **not run** yet. |
| `prompt` / `agent` | Parsed, loads, **not run**: both are a model call wearing a hook's clothes, which is a different trust surface. |

## Command execution, and the two accepted differences

A command hook runs through `broker.clear_call` — the same jailed
path the worktree observation's `git` and the `bash` tool take —
with the session workspace as `cwd`, the session environment
(`PATH`/`HOME`/`TMPDIR` plus `[tools] env` names) as its env, the
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
   inherited one: `CLAUDE_PROJECT_DIR` and a leading `~` both mean
   the workspace, `CLAUDE_ENV_FILE` points at a session-owned file,
   and no daemon secret reaches a hook's environment by default.

An `allow` decision never raises authority: every imported gate sits
*after* the harness's own clearance and can only lower, never widen.

## The event matrix

Every event the pinned contract documents. "Mapping" names the
harness moment the event composes into; "tested" names the test
modules holding the row.

| Event | Mapping | Tested | Gap / note |
|---|---|---|---|
| `SessionStart` | Boot + run-start context injection; plain stdout and `additionalContext` both become model context | `hookdecisions_test`, `hookwire_test` | `source` matchers distinguish `startup`/`resume`/`compact`/`clear`; Loom has no `/clear` and no session *fork*, so those sources never fire |
| `UserPromptSubmit` | Prompt admission | `hookdecisions_test` | **The gap this issue owns:** the harness has no prompt-admission seam yet. Blocking and context injection are decided and designed; the gateway slot is the remaining work. |
| `PreToolUse` | Tool clearance, after the harness's own clearance; `allow`/`deny`/`ask`/exit-2, `updatedInput` rewrite | `hookdecisions_test`, `hookwire_test`, `hookrunner_test` | `ask` rides the escalation plane; `defer` is a non-interactive-mode concept with no Loom counterpart, parsed and noted |
| `PostToolUse` | Result fold: `decision: "block"` rides beside the original result; `updatedToolOutput` rewrites the content the model reads | `hookdecisions_test` | Replacement is narrowed to content — `is_error`, cost, and coordinates stay the harness's, the same rule the native `tool_result` fold holds |
| `PreCompact` | The `before_compact` note appended to the summarizer's input | `hookdecisions_test` | **No veto, by existing ruling** ("a hook that could stop a compaction would not be safe"): Claude can block compaction; Loom's row says a veto needs its own protocol note against the compaction ruling |
| `Stop` | The run-end boundary: `decision: "block"` / exit 2 places the born-placed follow-up and continues the run; `stop_hook_active` maps to the consecutive-follow-up count; the 8-block override maps to a harness-side cap | `hookdecisions_test`, `hookwire_test` | The gate composes onto the existing `run_end` slot, which is what keeps it durable under replay |
| `SubagentStop` | The same run-end boundary, scoped to the subagent's strand | — | Rides `Stop`'s mapping; per-strand scoping lands with the serve wiring |
| `Notification` | — | — | No TUI notification moment exists; entries load, `once`/`terminalSequence` noted |
| `PermissionRequest` | — | — | The escalation seam exists (`client/escalate`); the wiring is the remaining work, recorded here rather than guessed |
| `MessageDisplay`, `TeammateIdle`, `ConfigChange`, `CwdChanged`, `DirectoryAdded`, `FileChanged`, `InstructionsLoaded`, `PostCompact`, `PreModelSwitch`, `PostModelSwitch`, `SubagentStart`, `TaskCreated`, `TaskCompleted`, `StopFailure`, `Setup`, `Elicitation`, `ElicitationResult`, `UserPromptExpansion`, `PostToolUseFailure`, `PostToolBatch`, `PermissionDenied`, `SessionEnd`, `WorktreeCreate`, `WorktreeRemove` | — | — | No harness moment; entries load without edits and the load-time notes name each one once, rather than refusing the collection or faking a fire |

The "declared-and-skipped" middle is deliberate: the issue's
acceptance is loading a collection **without editing it**, and a
collection carrying a `MessageDisplay` hook must load as much as one
without it — while the operator sees, at load time, which entries
will never fire and why.

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
settings file is trusted on first sight — it is the operator's file
on the operator's machine, the same trust it carries in Claude; a
project file arrives with the repository and asks first, the same
posture the extension install record takes. `loom hooks` (list,
trust, revoke, convert) is the CLI surface.
