# The shared scenario for every concept

Every concept in this bracket draws the same moment, so the owner compares
designs and not data. Use these names and numbers verbatim in mockups. A
concept may leave an item out only if its design deliberately does not
surface that kind, and must then say where the item went.

## The moment

It is 14:20. The owner left at 11:05 and is back at their desk (then, in a
second frame, checks the page on a phone over Tailscale). One daemon, two
workspaces, six sessions. The owner is the session owner on all of them; a
teammate, **Bob**, is an operator on `storage/branch-index-repair`.

### Workspace `loom` (repo root `~/src/loom`)

1. **`coord/web-inbox`** — a coordinator session. It runs project mode with
   a goal, "Ship the attention inbox", phase *build*, milestones 3 of 5
   done, 412k of 1.2M tokens used. It has three delegate sub-agents:
   - `sub:fact-sheet` — **settled** 2h ago, result returned.
   - `sub:mockup-a` — **working**, 14 min into a turn, editing
     `packages/web_view/src/web_view/inbox.gleam`.
   - `sub:mockup-b` — **stuck**: its last turn failed with a provider
     rate-limit error at 13:52 and has not retried.
   The coordinator has **one question** for the owner, asked at 13:40:
   *"Should closed items fold under open ones, or move to a separate
   'Done' list?"* Options: (1) fold under open — **recommended**, matches
   the Inbox plugin and keeps context; (2) separate Done list; (3) hide
   after 24h.
2. **`storage/branch-index-repair`** — **waiting on approval** since 12:58.
   A `code_mode` program wants `proc.run` of `sqlite3 ~/.loom/store.db
   'PRAGMA integrity_check'` with **network off** but **a write grant to
   `~/.loom`** outside the workspace. Bob has seen it (he is present on the
   session) but has not decided. Policy: `workspace-write · network off`.
3. **`fix/hashline-replay`** — **done, ready to review.** Finished at
   12:31. Worktree diff `+412 −88` across 7 files; tests reported green by
   the agent (`make check-core` exit 0). The agent wrote a summary and
   **two finds** while working:
   - *Risk:* "`hashline.replay` silently skips entries whose digest is
     empty; a truncated store would replay short with no error."
   - *Idea:* "The replay loop could reuse `machine/codec`'s first-match
     walk and drop a closure per entry."
4. **`wp-j/vetting-lint`** — **working**, 3 min into a turn, no attention
   needed. Its PR **#1261** has **1 failing check** (`lint (R11)`) and **2
   unresolved review comments** from Bob.

### Workspace `aegis` (repo root `~/src/aegis`)

5. **`runner/pod-reach`** — **idle**, asked a question at 11:20 and has
   been waiting since: *"The runner pod has no `/tmp` write. Use the
   scratch tmpfs (recommended), mount an emptyDir, or skip the cache?"*
6. **`docs/threat-model`** — **idle, nothing pending.** Last activity
   yesterday.

### Cross-session

- At 13:15, `runner/pod-reach · main` sent a **peer message** to
  `storage/branch-index-repair · main`: "Does the integrity check need the
  write grant, or can it run read-only?" Stored, not answered.

## The totals the owner should be able to read at a glance

- Needs the owner now: **4** (the approval, two questions, the stuck
  delegate).
- Ready for review: **1** session (`fix/hashline-replay`) and **1** PR with
  blockers (#1261).
- Finds waiting: **2**.
- Working without help: **2** (`sub:mockup-a`, `wp-j/vetting-lint`).
- Quiet: **2** (`docs/threat-model`, `sub:fact-sheet` settled).
