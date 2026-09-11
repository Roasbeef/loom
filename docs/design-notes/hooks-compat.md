# Design note: reusing Claude Code hooks unchanged (issue #350)

Status: design, agreed with the owner 2026-09-11. This note fixes the
shape before implementation. The contract is pinned verbatim at
`docs/design-notes/claude-hooks-contract.md` (fetched 2026-09-11); the
Codex hooks page is the secondary reference for the TOML layer shape and
the trust-review pattern. Where this note and the pinned contract
disagree about Claude behavior, the contract wins.

## The goal, stated as a boundary

An operator's existing hook collection — `~/.claude/settings.json`, a
repo's `.claude/settings.json`, a plugin's `hooks/hooks.json` — loads
into Loom **without editing its entries or its scripts**, and behaves
nearly the same: same events, same matcher semantics, same JSON on
stdin, same exit-code and stdout-JSON decisions, same timeouts, same
async behavior. "Nearly" is budgeted, not silent: every remaining
difference is in the parity matrix with a reason, and the owner accepts
the list before the issue closes.

Two formats are accepted, the way Codex accepts two:

- **Claude shape**, verbatim: the `hooks` object of a settings file,
  with matcher groups and handler arrays, JSON. Loaded from the
  documented locations, never rewritten.
- **Loom shape**, native TOML: `[[hooks.PreToolUse]]` matcher tables
  with nested `[[hooks.PreToolUse.hooks]]` handler tables, inline in
  `loom.toml` or in a standalone hooks file. A `loom hooks convert`
  CLI command turns the Claude shape into this one, losslessly, for
  operators who prefer their configs native.

Both shapes produce the same in-memory model, so there is one bus, one
runner, and one trust story regardless of which format a hook arrived
in. Sources **merge** across layers (user, project, plugin); a
higher-precedence layer never replaces a lower one's hooks. The
Claude/Codex precedence table is the spec here: hooks from all matching
groups all run, concurrently for the same event.

## The vocabulary, and where each event lands

The imported event names are kept verbatim (`PreToolUse`, not a renamed
`tool_call`): the parity target is reuse, and renaming is the one thing
that guarantees a rewrite. Internally each event maps onto an existing
harness moment — the compatibility layer is a translator at the
boundary, and the native extension API (`[[hook]]` in
`extension.toml`, `ext/hook.gleam`) is untouched beside it.

| Imported event | Harness moment | Decision carried |
|---|---|---|
| `SessionStart` | session boot, before first prompt (bus `session_start`); re-fired on compaction continuation for `source: "compact"` | plain stdout → run-start context; JSON `additionalContext` the same |
| `UserPromptSubmit` | prompt admission, before a queued turn is placed | plain stdout / `additionalContext` → injected beside the prompt; `decision: "block"` rejects the prompt |
| `PreToolUse` | tool clearance, after the harness's own clearance passed (`cleared` in `client/extension/hooks.gleam`) | `permissionDecision: allow/deny/ask`, exit 2 = deny; `updatedInput` rewrites arguments |
| `PostToolUse` | tool settled, before the reply is committed (`ran`/`fold_tool_result`) | `decision: "block"` + `reason` becomes the visible result beside the original; `updatedToolOutput` rewrites content |
| `PreCompact` | compaction decided, before the summary request (`compaction_note`) | `additionalContext`-style note appended to summarizer input |
| `Stop` | run may finish (`run_end`, consulted at `finish_boundary`, `machine/planner.gleam:1020`) | `decision: "block"` + `reason` → the born-placed follow-up message; the run continues |
| `SubagentStop` | subagent run may finish (same slot, strand-scoped) | as `Stop` |
| `Notification` | TUI notification moment | none (side effects) |
| `PermissionRequest` | escalation raised, before the prompt is shown | `decision.behavior: allow/deny` answers the prompt |

Events with no harness moment at all (`MessageDisplay`, `TeammateIdle`,
`WorktreeCreate`, …) are in the matrix as **declared-and-skipped**: the
loader accepts their entries (so a collection loads without edits) and
the matrix says which moments do not exist in Loom yet. Skipped-with-log
is the honest middle: it does not fake a fire, and it does not refuse
the collection.

The `Stop` mapping is the load-bearing one, and the slot already
exists: `finish_boundary` consults `run_end` at every may-finish
boundary, and a `Some(message)` follow-up commits a new user entry and
continues with `NeedAssistant`. That is exactly Claude's "decision:
block continues the conversation," with the harness's own durability
replay rules. `stop_hook_active` maps to a per-operation count of
follow-ups this gate has placed; the 8-consecutive-block override maps
to a harness-side cap on that count, after which the gate stops asking
and the run finishes.

## The runner: commands go through the broker

Claude command hooks are shell strings — `sh -c` semantics, `~`
expansion, `$(...)`, pipes. That is a deliberate, documented departure
for this tree (every in-tree spawn is argv-only), and it is
unavoidable: the acceptance case is the owner's existing scripts,
unedited. The runner therefore runs each command as
`["sh", "-c", command]` (or `args` as argv when the entry has `args`)
through `broker.clear_call` — the same call path `worktree_diff`'s git
runs take — with:

- **cwd** = the session workspace;
- **env** = the session environment (`serve.session_environment`
  plus the `[tools] env` names), **plus** the documented Claude hook
  variables where they have a meaning (`CLAUDE_PROJECT_DIR`, and
  `CLAUDE_ENV_FILE` pointing at a session-owned env file appended to
  subsequent tool environments);
- **stdin** = the event's JSON input, exactly the pinned contract's
  field set for that event;
- **stdout/stderr/exit code** captured with per-hook `timeout` seconds
  as the wall deadline, the helper's TERM-then-KILL ladder on expiry;
  a timed-out hook is cancelled and its output discarded (the contract:
  a timed-out PreToolUse does not block).

**The allow decision retains Loom's authority.** A `PreToolUse` hook's
`permissionDecision: "allow"` feeds the gate after the harness's own
clearance; the hook cannot raise authority, only lower it — the same
direction every other in-tree decision carries.

**Two documented differences, accepted up front:** (1) the hook runs
jailed under the session's sandbox policy, so a hook that reaches for
the operator's keychain or an unwritable path fails rather than
succeeding; an operator whose hook needs host reach names it in `[tools]
env`/`[net]`-style config, the same discipline an MCP server follows.
(2) the environment is the session environment, not the daemon's whole
inherited environment — missing-permission visibility comes from the
load-time check below, not from ambient env.

## Trust: recorded, hash-pinned, per source

Codex's pattern, adopted: non-managed hook sources need explicit trust
before they run, recorded against the **hash of the hook definition**
(a source file plus its parsed entries), so a changed hook re-enters
review. Repo-committed `.claude/settings.json` is a supply path the
extension trust story already treats seriously (`extension/record.gleam`
is the template: who/when/what, re-derived, refused on drift). The
owner's own user-level collection is a user trust decision recorded
once; a project-level hooks file is a project trust decision surfaced
at session open. `loom hooks` (list/trust/revoke/convert) is the CLI
surface, mirroring `loom ext`.

## Code mode: the boundary, stated once

A direct tool call fires the tool events through the clearance gate.
The same operation invoked through code mode is a `cap_call` at the
broker and is **not** a tool event: firing both would double-charge
one operation, and firing only the direct path would let code mode
bypass every gate. The matrix pins the exact seam: imported tool hooks
cover the model's *tool* surface; code-mode capability calls carry
their own vetting (the seam allowlists) and are out of scope for this
issue's tool events. That is the one place "nearly 1:1" spends its
budget on semantics rather than mechanics, and it is recorded because
the issue asks for the boundary to be documented, not guessed.

## What this note deliberately does not decide

- Whether `PreCompact` gains a veto (Claude can block compaction;
  Loom's ruling is never-veto). The matrix carries it as a gap; a veto
  needs a `protocol-change` note against the compaction ruling.
- `agent_settled` has no producer; `SubagentStop` rides the same
  `run_end` slot scoped to the subagent's strand, which supplies one.
- HTTP/prompt/agent handler types (`type: "http"`, `"prompt"`,
  `"agent"`) — command handlers first, per the issue; the others are
  matrix rows marked "parsed, not run."
