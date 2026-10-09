# Concept C: one column that unfolds

**Status: proposed, one of three concepts for [issue #655](https://github.com/Roasbeef/loom/issues/655), for the owner's pick.** No production code changes.

The terminal is one calm column by default, with the strand roster under the
composer as the collapsed form of a Strands tab; a single tabbed panel
(Strands, Changes, Trace, Session) unfolds beside the transcript when the width
allows and over it when it does not, a pinned sessions column is a third fold
at wide widths only, and the two views the owner named as sloppy (the session
picker and the agent workspace) are rebuilt first, on aligned columns, with a
detail pane that is never empty.

The web design [A2](../web-design.md) is the reference, not the template. What
carries over is its content model: strands are the first-class object, the
right side is tabs, context switching happens at the sides while the
transcript stays calm, and the layout is remembered per workspace. What does
not carry over is three fixed columns. A character grid at 120 columns has
room for two, and at 80 for one, so in this concept a column is a fold the
operator opens, not a fixture of the page.

Nothing in this concept rebinds a key the owner relies on today: `←` from an
empty composer still opens the session picker and `↓` from an idle composer
still enters the strip; the concept never moved them.

The "option (d)" decision (moving the terminal onto `step.update` with a pure
callback) is not decided here. It lands in
`docs/review/terminal-option-d-2026-09-30.md`, measured separately.

The frames are plain-text grids at the exact sizes claimed
(`C-fable-<name>.txt`, 200×50, 120×40 and 80×24) and one self-contained page,
[`C-fable.html`](C-fable.html), renders them in the terminal's own palette
(`tui/theme.gleam` for dark, the light mapping in `tui/appearance.gleam`). The
PNGs are headless-Chrome screenshots of that page. Section 13 lists them all.

## 1. The two views that come first

The owner's stated pain (2026-09-30) is how two existing views look beside
Codex and Claude Code: the session picker and the agent workspace. They are
the first two slices of the plan (section 14), ahead of the layout work. Each
gets a "before" capture from the real client, a list of what is sloppy, an
"after" mockup, and its data sources.

The "before" captures were made in a private tmux session from this worktree
at `f9927f7d9`. The agent workspace is `gleam dev agents dark`, the shipped
six-agent fixture through the shipped loop. The picker was drawn by the
shipped `render` (`tui/session_selector.gleam:815`) over a seven-session
fixture page, because `--demo` has no daemon to list sessions from and
`open_session_selector` (`tui/submit.gleam:156`) refuses without a control
host. The frames are the real renderer's output either way.

### 1.1 The session picker (`←`)

| State | Before | After (dark) | After (light) | Grid |
|---|---|---|---|---|
| 120×40, all sessions | [before](C-fable-before-picker-120-all.png) · [text](C-fable-before-picker-120-all.txt) | [picker-120](C-fable-picker-120-dark.png) | [light](C-fable-picker-120-light.png) | [txt](C-fable-picker-120.txt) |
| 120×40, Needs you filter | [before](C-fable-before-picker-120-needs.png) · [text](C-fable-before-picker-120-needs.txt) | [picker-120-needs](C-fable-picker-120-needs-dark.png) | [light](C-fable-picker-120-needs-light.png) | [txt](C-fable-picker-120-needs.txt) |
| 120×40, empty filter | — | [picker-120-empty](C-fable-picker-120-empty-dark.png) | [light](C-fable-picker-120-empty-light.png) | [txt](C-fable-picker-120-empty.txt) |
| 80×24 | [before](C-fable-before-picker-80-all.png) · [text](C-fable-before-picker-80-all.txt) | [picker-80](C-fable-picker-80-dark.png) | [light](C-fable-picker-80-light.png) | [txt](C-fable-picker-80.txt) |

**What is sloppy today**, read off the captures:

- Every row repeats the identity prefix (`· 01a0a1e2-af88`) and a wide
  picker adds a bracketed lifecycle tag, so the row reads
  `▸ ● ws · main · 01a0a1e2-af88                 current`. The identity is the
  same twelve characters on every row, so it tells the operator nothing, and
  `row_lines` (`tui/session_selector.gleam:998`) puts it there to keep two
  same-named sessions apart, which the detail pane already does.
- Nothing lines up. The name, the tag and the identity are one string, so
  the second column starts wherever the name ends.
- The workspace header is the full path (`/Users/operator/code/pi-gui 3`),
  which at three deep worktrees is most of the width, and the count is glued
  to it.
- The `current` word is a column of its own and the only right-aligned thing.
- The filter counts are the one good idea here, but they sit inside the
  frame on their own row with a rule under them, spending three rows.
- The detail pane is a stack of `Heading` / `value` pairs with a blank line
  between each (`Last message`, `Agents`, `Workspace`, `Model`, `Session`),
  so at 120×40 it is twelve rows of mostly air and still repeats the
  workspace and the identity the list already showed.
- At 80×24 the two-line rows (`row_lines`'s `ListOnly` arm) fill the frame
  with `working · 01a0a1e2-af88` lines, the help line is cut mid-word
  (`d arc…`), and the frame is drawn over the transcript's gutter glyphs.
- The empty state is a sentence in the list column; the filter tabs keep
  their counts, which is right, but nothing says what key leaves the
  state.

**After.** One title row carries the name and the filter tabs with their
counts (`All 7 · Needs you 1 · Working 2 · Idle 1 · Inactive 3`), the active
one inverted, so the counts cost no body rows. Rows are four aligned columns:
the presence glyph, the name, a state phrase, and the model, with the cursor
row raised. Workspace headers are `~`-shortened paths with the count
right-aligned. The identity appears once, in the detail pane. The detail pane
is a short card: name, state line, `LAST MESSAGE` wrapped to three lines,
`STRANDS` as one row each with the glyph and current action, then one line of
figures and one of identity. It is never empty: a row with no activity answer
shows its lifecycle and `created 3d ago`. At 80×24 there is no pane; a
two-line preview of the highlighted row sits above the help line. An empty
filter says what to press next and keeps the counts.

**Data.** Everything drawn exists today except one figure. Rows come from
`Session` (`tui/daemon/protocol.gleam:452`) and the page from `Page`
(`tui/daemon/protocol.gleam:412`). The state phrase, counts, last message,
model and the strand rows come from `Activity`
(`tui/daemon/protocol.gleam:300`) with its `ActivityState`
(`tui/daemon/protocol.gleam:325`) and `GlanceLine`
(`tui/daemon/protocol.gleam:352`), which `observe`
(`tui/session_selector.gleam:405`) folds in from the `sessions.activity` poll
that `service_activity` (`tui/session_control.gleam:1442`) runs while the
picker is open. The filter tabs are `Filter` (`tui/session_selector.gleam:75`)
and the glyphs are `Presence` (`tui/session_selector.gleam:73`). The one
figure that does not exist is an age for a resident session's last activity:
`created_at` is the only timestamp a row carries, so the mockup shows `created
3d ago` for saved rows and no age for resident ones. A `last_activity_ms` on
the activity reply would be a change to the control protocol, so a
`protocol-change/NNN.md`; the view works without it.

### 1.2 The agent workspace (`Ctrl+O`, `F2`, `/agents`)

| State | Before | After (dark) | After (light) | Grid |
|---|---|---|---|---|
| 120×40, seven strands, one needs approval, one failed, a long task | [before](C-fable-before-agents-120-workspace.png) · [text](C-fable-before-agents-120-workspace.txt) | [agents-120](C-fable-agents-120-dark.png) | [light](C-fable-agents-120-light.png) | [txt](C-fable-agents-120.txt) |
| 120×40, the failed strand selected | [before, Messages tab](C-fable-before-agents-120-messages.png) · [text](C-fable-before-agents-120-messages.txt) | [agents-120-failed](C-fable-agents-120-failed-dark.png) | [light](C-fable-agents-120-failed-light.png) | [txt](C-fable-agents-120-failed.txt) |
| 120×40, main only (empty) | — | [agents-120-empty](C-fable-agents-120-empty-dark.png) | [light](C-fable-agents-120-empty-light.png) | [txt](C-fable-agents-120-empty.txt) |
| 80×24 | [before](C-fable-before-agents-80-workspace.png) · [text](C-fable-before-agents-80-workspace.txt) | [agents-80](C-fable-agents-80-dark.png) | [light](C-fable-agents-80-light.png) | [txt](C-fable-agents-80.txt) |
| The strip under the footer today (120 and 80) | [120](C-fable-before-agents-120-strip.png) · [80](C-fable-before-agents-80-strip.png) | see section 3 | | |

**What is sloppy today**, read off the captures:

- The roster column takes four rows per strand (`roster_lines`,
  `tui/agents.gleam:631`): name, task cut mid-word (`Integrate the agent
  workspace a…`), state with the activity cut from the left
  (`…n-label check failed`), and a blank. Six strands need 24 rows, so the
  column scrolls at 120×40 with the advisor out of view.
- The section headings (`SESSION`, `STRANDS`, `ADVISOR · independent review`)
  cost a row each and the `· to` suffix on the active row is a word where a
  mark would do.
- The detail pane is `Heading` / `value` / blank for seven sections
  (`detail_lines`, `tui/agents.gleam:1039`); `CURRENT STATE` says
  `agent_send` on its own line, `RECENT ACTIVITY` lists `· Result unavailable
  · agent_wait`, and `INPUT` says `3 received, awaiting delivery` without
  saying from whom. Elapsed time and tokens, which the strip shows, are not in
  the pane at all.
- The sub-tabs row (`[1 Activity]  2 Messages  3 Notes  4 Collaborate`) is
  drawn in the detail column, so it moves when the column does, and the three
  help rows at the bottom repeat the recipient the composer's rule already
  names.
- At 80×24 the stacked layout (`render_workspace`, `tui/agents.gleam:438`)
  spends its ten rows on `▸ main · 1/6`, the sub-tab row, the name, and three
  help rows, leaving one row (`main`) for the detail. The owner cannot see
  what main is doing.
- Dimming is inconsistent: the detail's quiet headings and the roster's
  quiet task share one grey with the help rows, and the selected row's raised
  background stops at the name.

**After.** The list is one row per strand on aligned columns: cursor, status
glyph, name, current action, elapsed, context, the same row the strip and the
Strands tab draw (section 3), so a strand looks the same in all three places.
A long name keeps its last seven characters (`adversarial-co…-48f3c1`), which
is how two reviewers with one prefix stay apart; today's strip cuts the suffix
off (`adversarial-code-revi…`). The cursor row is raised across the full
width. The title carries the counts (`7 · 4 working · 1 needs you · 1
failed`). The detail pane for the selected strand is a card with short
headings in one quiet grey: the identity line, `TASK` wrapped to three lines
with `Ctrl+g shows all 14 lines`, `NOW` (the running call, its state and
elapsed time), `MESSAGES` (the latest in and out, with ages), `INBOX` (unread
count, pending approvals, held inputs), and `RECENT` tools. A failed strand's
card leads with `FAILED` and the error excerpt, and says `x is inert`. The
empty state says `main is the only strand` and names `/fork`. At 80×24 the
list is a four-row window with `+3 more` and the detail is one line per
heading.

**Data.** The row comes from `Row` (`session_view/agent_view.gleam:79`),
whose `Status` (`session_view/agent_view.gleam:52`) carries the glyph and
`label` (`session_view/agent_view.gleam:554`) the word, and from `Line`
(`session_view/agent_roster.gleam:84`), which adds elapsed time and context
size; `lines` (`session_view/agent_roster.gleam:355`) is the order. The task,
activity, latest update, pending input, recent tools and approvals are the
`Row`'s own fields. Sent messages are `Item`
(`session_view/agent_messages.gleam:52`), held in `agent_messages`
(`session_view/model.gleam:263`), with the delivery `State`
(`session_view/agent_messages.gleam:29`). Received messages and the inbox are
the gap: section 9.2 says what exists and what needs a protocol change. The
failed strand's error excerpt is the `update` and `activity` fields the
capture already projects.

## 2. What changes from today and why

Today's terminal (`layout`, `tui/layout.gleam:105`) is a header, a body, a
composer and a footer with the agent strip under it. The body holds the
transcript and, at the right, either the agent rail (34 cells, from 100
columns, `body_layout` at `tui/layout.gleam:138`) or the changes pane (up to
72 cells, from 140 columns, `diff_pane_width` at `tui/layout.gleam:359`), never
both. Eight more surfaces are overlays or transcript replacements, each with
its own keys: the agent workspace, the picker, the model selector, the
approval dialog, the peer-link and access overlays, `/notes`, `/summary`,
`/context`, `/diff` when narrow, and the queue editor.

What changes:

1. **The two side panes become one tabbed panel.** The rail and the changes
   pane become the Strands and Changes tabs of one right panel, and `/summary`,
   `/context`'s figures and the goal row move into a Session tab, with a Trace
   tab for code mode. One panel has one key grammar (section 7). The full
   agent workspace stays as the panel's wide form (section 1.2).
2. **The strip is the Strands tab's collapsed form.** When the panel shows
   Strands, the strip is not drawn; when the panel is hidden or the terminal is
   narrow, the strip under the footer is the same rows (`lines`,
   `session_view/agent_roster.gleam:355`). Nothing is drawn twice.
3. **Columns are folds.** `Shift+Tab` shows or hides the panel, as it toggles
   the rail today (`toggle_agent_rail`, `tui/interaction.gleam:1612`). A column
   that does not fit is not drawn, and the preference is kept, as the rail's
   is today. The sessions column exists only from 180 columns and is pinned
   with `/layout sessions`.
4. **The transcript gets a one-cell timeline gutter.** A `│` in the row's
   strand hue, `●` where another strand crosses in (a spawn, a result, a
   nudge, a peer message), which is A2's timeline in one cell.
5. **Repeated calls and errors collapse to one counted row.** `✓ agent_wait ·
   2 subagents ×15 · 4m 12s · latest 4s ago` and `! error · http 429 ×20`.
6. **Harness notices are dim one-line notes**, never `› User` turns.
7. **The approval card is a full-width block in the dock**, above the
   composer, with numbered choices and a reason line, nothing selected on
   opening.
8. **The composer's status band names the cancel key** (`◐ thinking · 9s ·
   esc interrupts`) and its top rule carries the session title as a badge when
   `main` is viewed, the sub-agent's task when a sub-agent is.
9. **Layout is remembered per workspace** in a file under the state root
   (section 10).

What does not change: the header, the footer's pieces, Enter/Tab/Esc in the
composer, `/` and the palette, `Ctrl+g`, `Ctrl+O`/`F2`, `Alt+q`, `←`, `↓`,
`PgUp`/`PgDn`, `End`, and `Ctrl+C`. Section 11 has the table.

## 3. What we took from omp

The owner sent oh-my-pi as evidence of what they find pleasant: dense but
calm, collapse by default, status merged into the input frame, sub-agent
progress inline, little chrome.

Taken:

- **Collapse by default with one key.** Tool groups, reasoning and results are
  already one row with `Ctrl+g`; the concept extends the same rule to repeated
  calls (`×15`), repeated errors (`×20`) and the code-mode call list
  (`7 calls · 1 failed`). The one key stays `Ctrl+g`.
- **Titled rules for structured results.** A running or failed code-mode
  program is a box whose top rule carries its state and name (`╭─ running ·
  check_subtract.gleam · 3 calls ─╮`), drawn with `render_panel_border`
  (`tui/render.gleam:304`). pi's running block is the same shape.
- **Sub-agent progress inline.** An `agent_wait` result row shows a tree line
  per awaited strand (`└ sub:main/adversarial-…-48f3c1 still working after
  30s`) using the roster's own words.
- **The activity line above the input with its cancel key**, which the band
  already has (`composer_status_lines`, `tui/layout.gleam:715`) minus the key.
- **Tinted blocks, not boxes**, for the two things the terminal already tints:
  the user turn and the assistant's prose. Tool calls stay one-line rows
  without a tint, because the owner's recordings show that a wall of tinted
  tool blocks is the wall of text they dislike.
- **Dates relative, links coloured**: already so.

Rejected:

- **One column with no panes at all.** The owner runs five to nine agents at
  once and glances at the roster; omp's inline tree answers "what did the task
  spawn", not "what is everybody doing now". So the default is one column at
  narrow widths and the roster stays a strip, but the panel exists and is a
  fold the operator opens.
- **Status merged into the input frame, no footer.** The owner's recordings
  show them reading the footer (ctx, cost, agent counts). The footer stays;
  the input's rule keeps the mode hints (`enter queues · tab steers`), which a
  powerline would push out. The session title moves onto that rule as a badge,
  which is the part of omp's idea that fits.
- **Reasoning dimmed in full.** Loom collapses reasoning to one row because
  walls of reasoning are the owner's first pain point (section 4). Dimmed walls
  are still walls.
- **An inline slash completion strip.** The palette anchored above the prompt
  is what the owner uses today and the drives brief lists it as working.
- **LSP diagnostics attached to the write.** Loom has no LSP; the code-mode
  compile error already sits under its call, which is the same idea.

## 4. What we took from the owner's drives

From the recordings of today's Loom terminal, each pain point is fixed in a
named frame:

| Pain point | Fix | Frame |
|---|---|---|
| Fifteen identical `✓ agent_wait · 2 subagents` rows | one counted row, `×15 · 4m 12s · latest 4s ago`, with the latest `└` line, `Ctrl+g` lists each | [standard-agents](C-fable-standard-agents-dark.png), [narrow-agents](C-fable-narrow-agents-dark.png) |
| A background-job loss notice drawn as a `› User` turn | `◌ loom · …` dim note, no bubble, `Ctrl+g` expands | [standard-agents](C-fable-standard-agents-dark.png) |
| A wall of `error provider returned http 429` | `! error · http 429 ×20 · 3m 10s · last 4s ago · retrying`, `Ctrl+g` lists each | [standard-errors](C-fable-standard-errors-dark.png) |
| Walls of reasoning and tool text | reasoning and tool groups stay one row each; the concept adds nothing to the transcript that is not one row collapsed | every frame |
| Hook and stop-hook notices as `User` turns | `◌ loom · stop hook · …` | [standard-errors](C-fable-standard-errors-dark.png) |
| Sub-agent rows truncated to a shared prefix (`adversarial-code-revi…` twice) | a long name keeps its last seven characters | [narrow-agents](C-fable-narrow-agents-dark.png), [agents-120](C-fable-agents-120-dark.png) |
| The scrollback bar without a position | `↓ Scrollback · 312 rows up · click or End for latest` | [standard-errors](C-fable-standard-errors-dark.png) |
| Codex's empty preview pane and `No matching tasks` | the picker's detail pane is never empty and the empty filter says what to press | [picker-120-empty](C-fable-picker-120-empty-dark.png) |

Taken from Claude Code and Codex in the same recordings: the agent list under
the input with aligned name, action, elapsed and tokens, and a selected row,
which is what the strip becomes; filter tabs with counts, which the picker
already has and now carries on its title row; the approval as a full-width
block under a rule with numbered choices, a key hint and a one-line reason,
which replaces the bottom-anchored dialog's three vertical choices, keeping
the rule that nothing is selected on opening and Enter confirms
(`render`, `tui/approval_panel.gleam:285`, keeps its capture of the exact
sequence, action and grants); the single footer line with an activity label
on the left, which the compact footer already is; and the pinned todo as one
line that expands.

Not taken: pi's strike-through for done tasks (terminals render it unevenly;
the `✓` glyph plus dim text carries it), and a full-screen command center,
since the picker is an overlay the operator reaches with one key and leaves
with one.

From the newer Codex recording (2026-09-30): tool groups with a failure count
in the header (`7 calls · 1 failed`, `Explored · 1 failed`) are taken for code
mode and tool groups; the short diff preview under a write is what the
compact `fs_edit` row already draws; one-line system notes for session events
(`Reconnected. No input was resent.`) are the same `◌ loom` note; the
non-blocking bottom menu for a choice that is not an approval is noted as a
later shape for advisor nudges and not drawn. Its `←` for agents is not taken,
on the owner's correction: `←` keeps the picker.

## 5. Which parts of A2 fit a character grid and which do not

| A2 element | Fits | How, or why not |
|---|---|---|
| Three fixed columns | partly | Two columns at 100 to 179 columns, three at 180 and above, one below 100. A column is a fold, never a fixture. |
| Left sidebar: workspaces and sessions, strand bars | yes, at ≥180 | A 26-cell column drawing the picker's grouped rows with presence glyphs; strand bars become one glyph per live strand in its hue. Below 180 the picker overlay is the same list. |
| Tabbed right panel | yes | Four tabs on the panel's top border; one is active; digits pick one while the panel has focus. |
| Strand cards with a cache ring | partly | One row per strand (name, status line, elapsed, context); the ring becomes the words the footer already shows (`cache ≤3m`), on the selected strand's card. |
| Timeline dots and strand tags | yes | A one-cell gutter in the strand's hue and a `●` at a crossing; tags are the strand's name in its hue. |
| Breadcrumb and `Esc` back to `main` | no | `Esc` in the composer is the interrupt (`interrupt_active`, `tui/interaction.gleam:1610`) and must stay so. The transcript heading reads `transcript / main ▸ sub:tests · ^O strands · /strand main`, and the way back is `Enter` on `main` in the Strands list, which is always its first row, or `/strand main`. |
| `⌘B` / `⌘⌥B` toggles | no | `Ctrl+B` is tmux's prefix and `Ctrl+Alt` chords do not survive every terminal. `Shift+Tab` toggles the panel, as it toggles the rail today; `/layout sessions` pins the sessions column. |
| Detail view of a strand inside the Strands tab | yes, differently | The cursor row's detail is always drawn below the list; there is no list-or-detail state, because browsing must not cost a focus. |
| Approval card in the dock | yes | Kept in the dock, as a full-width block under a rule. The panel carries no decision control. |
| `Alex is typing` | no | Not in the protocol, as the web note says. |
| Todo line above the composer | yes | Today's panel in its one-row form by default. |
| Changes from the session's edits | yes, as the fallback | The terminal can read the worktree, so Changes is `/diff`'s observation first, with `fold` (`session_view/changes_view.gleam:210`) as the labelled fallback it already uses. |
| Trace with timing bars | no, until #656 | The tab draws the latest program's calls untimed; section 9.1 says what the result carries today. |
| Layout remembered per workspace | yes | A file under the state root, section 10. |
| Theme toggle | no | The palette is decided at launch from the terminal's environment (`detect`, `tui/appearance.gleam:46`). |

## 6. The layout at three widths

Rows, from the top: the header (1), the body, the todo line (1, or the
expanded panel), the queue card when inputs are held, the approval block when
one is pending (5), the composer (its rule, the status band, the editor, its
rule), the footer (1 row from 100 columns, 2 below), and the strip when it is
drawn. The body holds the columns; everything under it spans the width, as
today, so the composer never loses width to a column.

| Width | Columns | Panel width | Strip |
|---|---|---|---|
| ≥ 180 | sessions (26, when pinned) · transcript · panel | 52 | hidden while the panel shows Strands |
| 100 to 179 | transcript · panel | `clamp(width × 7 / 20, 36, 52)`, 42 at 120 | hidden while the panel shows Strands |
| < 100 | transcript | none beside it; `Shift+Tab` or `Ctrl+O` opens the panel over the transcript, `Esc` returns | drawn, from 16 rows and two agents, up to a quarter of the height |

The transcript keeps at least 68 cells beside a panel, the rule
`diff_pane_width` (`tui/layout.gleam:359`) applies today. The strip's height
rule is unchanged (`height_for_count`, `tui/agent_strip.gleam:212`). The
rows a panel's tab needs are never taken from the composer.

| Frame | Dark | Light | Grid |
|---|---|---|---|
| Wide default, 200×50 | [wide-default](C-fable-wide-default-dark.png) | [light](C-fable-wide-default-light.png) | [txt](C-fable-wide-default.txt) |
| Wide, both columns hidden | [wide-collapsed](C-fable-wide-collapsed-dark.png) | [light](C-fable-wide-collapsed-light.png) | [txt](C-fable-wide-collapsed.txt) |
| Standard default, 120×40 | [standard-default](C-fable-standard-default-dark.png) | [light](C-fable-standard-default-light.png) | [txt](C-fable-standard-default.txt) |
| Narrow default, 80×24 | [narrow-default](C-fable-narrow-default-dark.png) | [light](C-fable-narrow-default-light.png) | [txt](C-fable-narrow-default.txt) |
| Narrow, panel over the transcript | [narrow-panel](C-fable-narrow-panel-dark.png) | [light](C-fable-narrow-panel-light.png) | [txt](C-fable-narrow-panel.txt) |
| Six agents, one needing approval, 120×40 | [standard-agents](C-fable-standard-agents-dark.png) | [light](C-fable-standard-agents-light.png) | [txt](C-fable-standard-agents.txt) |
| Six agents, one needing approval, 80×24 | [narrow-agents](C-fable-narrow-agents-dark.png) | [light](C-fable-narrow-agents-light.png) | [txt](C-fable-narrow-agents.txt) |
| Collapsed 429s and the scrollback position | [standard-errors](C-fable-standard-errors-dark.png) | [light](C-fable-standard-errors-light.png) | [txt](C-fable-standard-errors.txt) |

How columns collapse: a hidden panel takes no width and its content is not
drawn; the preference (`agent_rail_visible`, `tui/model.gleam:540`, renamed
for the panel) is kept when the width drops below the column's threshold and
honoured again when it grows, which is how the rail behaves today. Hiding the
panel while the Strands tab had the keyboard returns the keyboard to the
composer. At 80×24 the six-agent frame shows the honest cost: with an approval
block and the strip, the transcript keeps five rows. The approval block is
what the operator must act on and the strip is what they asked to keep, so the
transcript is what gives.

## 7. The right panel: tabs and keys

The tabs are `1 Strands  2 Changes  3 Trace  4 Session`, drawn on the panel's
top border, the active one in the signal colour, with `!` after `Strands`
when a strand needs a decision (`needing`,
`session_view/strand_card.gleam:69`). The panel has keyboard focus or the
composer does; the panel's border is drawn in the signal colour while it has
focus, and the composer's top rule says what the keys do, as it does for the
strip today (`input_title_keys`, `tui/render.gleam:2023`).

| Key, panel focused | Does |
|---|---|
| `1` `2` `3` `4`, `←` `→` | pick a tab |
| `↑` `↓` | move the cursor (a strand, a file, a job) |
| `Enter` | act on the cursor row: focus the strand; open the file in the transcript's full view; open the job in `/summary` |
| `x` | stop the strand under the cursor (`stop_strand` today) |
| `a` | open the approval of the strand under the cursor |
| `n` | next strand needing attention |
| `m` | scroll the detail to `MESSAGES`; `Ctrl+g` shows a message in full |
| `r` | refresh the tab's read (worktree, jobs, notes) |
| `PgUp` `PgDn` | scroll the tab's body |
| `Tab` | keyboard back to the composer, panel stays |
| `Esc` | keyboard back to the composer, panel stays |

| Key, composer focused | Does | Today |
|---|---|---|
| `Shift+Tab` | show or hide the panel | toggles the rail (`toggle_agent_rail`, `tui/submit.gleam:432`) |
| `Ctrl+O`, `F2` | show the panel on Strands and give it the keyboard; at < 100 columns, open the workspace over the transcript | opens the workspace (`open_agents`, `tui/submit.gleam:60`) |
| `↓` on an idle composer | enter the Strands list (the strip when the panel is hidden) | enters the strip (`down_from_composer`, `tui/interaction.gleam:1490`) |
| `Ctrl+D` | focus the Changes tab's navigator | toggles the diff navigator's focus (`tui/interaction.gleam:1382`, the `worktree` focus) |
| `/diff` | show the panel on Changes and request the worktree read | opens the changes pane |
| `/summary`, `/context`, `/goal` | show the panel on Session, scrolled to the row | each opens its own surface |
| `/notes` | the Strands detail's `NOTES` section for the active strand; the full notes browser stays reachable from it with `Enter` | opens the notes browser over the transcript |
| `/layout sessions`, `/layout panel`, `/layout reset` | pin or unpin the sessions column, the panel, or forget the workspace's layout | — |

The Strands tab at 42 cells shows the list and a compact detail; at 52 the
same with longer lines; the agent workspace of section 1.2 is the same list
and detail at the full width, which is what `Ctrl+O` opens when the panel
cannot fit beside the transcript. One list, one detail, three sizes.

| Frame | Dark | Light | Grid |
|---|---|---|---|
| Changes tab | [standard-changes](C-fable-standard-changes-dark.png) | [light](C-fable-standard-changes-light.png) | [txt](C-fable-standard-changes.txt) |
| Trace tab | [standard-trace](C-fable-standard-trace-dark.png) | [light](C-fable-standard-trace-light.png) | [txt](C-fable-standard-trace.txt) |
| Session tab | [standard-session](C-fable-standard-session-dark.png) | [light](C-fable-standard-session-light.png) | [txt](C-fable-standard-session.txt) |

## 8. Strand focus from the timeline

Focusing a strand in the terminal is `switch_active_strand`
(`tui/submit.gleam:533`): it parks the draft, cancels the lane's unsent
frames, runs `focus` (`session_view/commands.gleam:266`) and `load_strand`
(`session_view/commands.gleam:299`), and the transcript, the composer's
recipient and the badge change together. Browsing must not cost that, so the
concept keeps today's split: arrows in the Strands list inspect (the detail
follows the cursor) and `Enter` focuses. That is one difference from A2, where
clicking a card both focuses and opens the detail; in a terminal the detail is
free and the focus is not.

Three places focus a strand:

- `Enter` on a row in the Strands list, the strip or the workspace.
- `/strand <name>`, as today.
- A mouse click on a strand's name in a transcript row (a spawn, a result, a
  nudge, a message) or on a row in the Strands list. Mouse is additive: a
  press and release without a drag on a name cell is a focus, a drag is the
  selection it is today.

The timeline gutter is navigation for the eye, not the keyboard: a `●` in a
strand's hue says where that strand crossed into this transcript. A row
cursor over the transcript, which would make the gutter keyboard-navigable,
is a large change (`transcript_anchor` positions, a third keyboard owner) and
is not proposed; the Strands list is the keyboard's timeline. Open question 3
asks whether the owner wants it anyway.

Focused view: `transcript / main ▸ sub:tests · ^O strands · /strand main` is
the heading, the composer's rule reads `To sub:tests` with the sub-agent's
task as the badge, and the Strands list raises the viewed row's mark to `›`.
The way back is `Enter` on `main`, the first row, or `/strand main`.

| Frame | Dark | Light | Grid |
|---|---|---|---|
| sub:tests focused, 120×40 | [standard-focus](C-fable-standard-focus-dark.png) | [light](C-fable-standard-focus-light.png) | [txt](C-fable-standard-focus.txt) |

The gutter's hue comes from `hue` (`session_view/turns.gleam:300`), which
colours a strand by its position among the captured strands and never by its
name, with `hues` (`session_view/turns.gleam:91`) sub-agent hues before they
repeat. The terminal's row projection would carry a hue beside each row the
way it carries anchors (`refresh_render_cache`, `tui/projection.gleam:79`),
derived from `pieces` (`session_view/turns.gleam:348`), which already decides
which strand a spawn, result, nudge or peer row belongs to. `tui/theme.gleam`
needs five strand hue constants beside `advisor` (`tui/theme.gleam:17`),
`signal` (`tui/theme.gleam:29`) and `current` (`tui/theme.gleam:32`), with
light values in `foreground` (`tui/appearance.gleam:142`). The mockups use
teal, olive, blue, coral and lavender. No wire change.

## 9. Content the new terminal must display well

### 9.1 Code mode

| Frame | Dark | Light | Grid |
|---|---|---|---|
| Possible today: a compile failure and a running program, 120×40 | [codemode-today-120](C-fable-codemode-today-120-dark.png) | [light](C-fable-codemode-today-120-light.png) | [txt](C-fable-codemode-today-120.txt) |
| Needs protocol-change: the capability call tree, 120×40 | [codemode-calls-120](C-fable-codemode-calls-120-dark.png) | [light](C-fable-codemode-calls-120-light.png) | [txt](C-fable-codemode-calls-120.txt) |
| Possible today, 80×24 | [codemode-80](C-fable-codemode-80-dark.png) | [light](C-fable-codemode-80-light.png) | [txt](C-fable-codemode-80.txt) |

**What it looks like, today.** A `code_mode` call is one row: state glyph,
`code_mode`, the program's name, its state and elapsed time (`× code_mode ·
vet_imports.gleam · compile failed · 4.8s`). Under it a titled box carries the
same words on its top rule. A failed program's box holds the failure (the
compile error with its line, or the run failure, or the vetting rejections)
and a `▸` row naming the program's line count and the sandbox's enforcement
summary, which `Ctrl+g` expands to the program and the full result. A running
program's box shows the first lines of the source with token styling, as the
compact row does today (`code_mode_program`,
`session_view/transcript_lines.gleam:2397`, six lines), then `▸ 15 more lines
· budget 12k of 40k · Ctrl+g`. A completed program is one row with its value
in a few words (`completed · 1.1s · value: 41 exports`). The Trace tab
(section 7) draws the latest program the same way.

**What it looks like after a protocol change.** The box lists the capability
calls in order, repeated calls counted (`✓ fs.read ×5
packages/cap/src/cap/*.gleam`), a failed call in the danger colour with its
error on a `└` line, and the row reads `7 calls · 1 failed`. That frame is
labelled as needing the change, in the frame itself and in its name.

**Data.** The program source and its name come from the invocation's
arguments (`code_mode_program`, `session_view/transcript_lines.gleam:3574`).
The state and the result come from the result's `status`, `value`, `message`,
`failure` and `rejections` fields (`execution_value`,
`tools/codemode.gleam:1336`), and the sandbox's enforcement report
(`Report`, `codemode/enforcement.gleam:56`). The call list does not exist on
the wire: capability calls are serviced inside the satellite and the broker
and no record of them reaches the result or a transcript entry, so neither
host can list them today. Section 6.3 of the web note assumed the page
already receives them; it does not, which also undercuts the first step of
#656. The call tree needs a new record on the result naming each call's
capability, target and outcome, which is a `protocol-change/NNN.md`; the
concept proposes that record first and the start and end times #656 plans as
a second step on the same record.

### 9.2 Messages from other strands

| Frame | Dark | Light | Grid |
|---|---|---|---|
| Possible today: sent rows attributed, a received message still a user turn, 120×40 | [messages-today-120](C-fable-messages-today-120-dark.png) | [light](C-fable-messages-today-120-light.png) | [txt](C-fable-messages-today-120.txt) |
| Needs protocol-change: received rows attributed by a strand origin, 120×40 | [messages-origin-120](C-fable-messages-origin-120-dark.png) | [light](C-fable-messages-origin-120-light.png) | [txt](C-fable-messages-origin-120.txt) |

**What it looks like, today.** A sent message is `→ main → sub:tests ·
agent_send · accepted · steered the open run · 2m ago` with the body indented
under it, the recipient's name in its hue, a `●` in the gutter and no
background, which separates it from a user turn (warm tint, `›`) and assistant
prose (cold tint, `◆`). A received message is still what it is today: a user
turn carrying the framing text `[message from sub:tests] … [end message. …]`,
drawn in the user tint with `origin none` on its heading so that it is at
least not mistaken for the operator. The frame says so on its last row.

**What it looks like after a protocol change.** A received message is `←
sub:tests → main · message · 30s ago`, the sender's name in its hue, the
arrow first so a reader scanning the gutter sees traffic, and the detail's
`MESSAGES` and `INBOX` lines show the latest in and out and the unread count.

**Data.** Sent messages exist: `Item` (`session_view/agent_messages.gleam:52`)
carries the source, target, body and `State`
(`session_view/agent_messages.gleam:29`: pending, failed, accepted, started),
projected from the sender's `agent_send` invocation and its result
(`agent_send`, `tools/agent.gleam:1904`; the steered delivery at
`steered_outcome`, `tools/agent.gleam:1977`). That state is receipt on the
sender's side and never proof that the recipient read the message, and the
row says `accepted`, not `read`.

Received messages cannot be attributed today. The Agency admits a
same-session message as a `UserMessage` with `origin: None` and the only
marker is the framing text, which a model can see and forge; the module doc
of `core/origin.gleam` forbids turning transcript text back into
attribution, and this concept does not parse `[message from`. The `Origin`
type names a principal or a peer session (`display_label`,
`core/origin.gleam:174`; `PeerOrigin` at `core/origin.gleam:190`) and has no
kind for a strand of the same session. Attributing a received message needs
a structured origin on the admitted message, a strand variant of
`message.Origin` stamped by the daemon, which changes the durable entry
format and so is a `protocol-change/NNN.md`. The second frame and slice 10
are labelled with it.

The inbox count is the other gap. #667 exposes inbox reads to the model
(`inbox`, `client/internal/message_inspection.gleam:36`, through the `inbox`
and `inbox_get` capabilities), not to a client. A client-side read of a
strand's inbox size would be a new read-only command on the conversation
channel, so part of the same protocol change; until then the detail's
`INBOX` line shows pending approvals and held inputs, which the capture
carries.

### 9.3 Messages from other sessions (peers)

| Frame | Dark | Light | Grid |
|---|---|---|---|
| An authenticated origin beside quoted text that is not one, 120×40 | [peers-120](C-fable-peers-120-dark.png) | [light](C-fable-peers-120-light.png) | [txt](C-fable-peers-120.txt) |

**What it looks like.** A peer message is `◇ peer · lnd-review / main ·
authenticated origin · 1m ago · /peers`, the session and strand in the peer's
hue, with the body under it, and a `●` in the gutter. A reply is `→ main →
peer lnd-review / main · peer_send · admitted · 50s ago`. The rule the design
makes visible: the `◇ peer` heading, the hue and the word `authenticated` are
drawn only from an entry whose `Origin` is a `PeerOrigin`
(`peer_message_lines`, `session_view/transcript_lines.gleam:2633`). Text that
merely says "peer · lnd-review / main · authenticated" is session text and is
drawn where it came from: in the frame, a tool result quotes exactly that line
and it appears as the tool's output in the quiet colour with a `└`, with no
heading, no hue and no gutter mark. No string in a body, a tool result or an
assistant message can produce the heading, because the heading is produced
from the closed type and the text is drawn as text.

**Data.** The origin is on the entry (`PeerOrigin`,
`core/origin.gleam:177`), validated by the daemon before the entry is written
(`validate_peer` in `core/origin.gleam`), and the terminal's collaboration
tab already projects peer messages from authenticated entry origins (`lines`,
`tui/collaboration_view.gleam:59`). The admission word on a reply (`admitted`)
is the peer send's result; "admitted" means durable admission and never that
the peer's model read it, which the row says with that word and not
"delivered". No wire change.

### 9.4 Inline images

| Frame | Dark | Light | Grid |
|---|---|---|---|
| The text fallback, 120×40 | [image-placeholder-120](C-fable-image-placeholder-120-dark.png) | [light](C-fable-image-placeholder-120-light.png) | [txt](C-fable-image-placeholder-120.txt) |
| A capable terminal draws the image, 120×40 | [image-rendered-120](C-fable-image-rendered-120-dark.png) | [light](C-fable-image-rendered-120-light.png) | [txt](C-fable-image-rendered-120.txt) |
| The text fallback, 80×24 | [image-placeholder-80](C-fable-image-placeholder-80-dark.png) | [light](C-fable-image-placeholder-80-light.png) | [txt](C-fable-image-placeholder-80.txt) |

**Three cases.** On a terminal with a graphics protocol the image is drawn
inside a labelled box whose top rule names the file, type, pixel size and
bytes, sized to a bounded number of cells (at most 64 by 10 at 120 columns;
the box's cells are reserved and the picture is placed over them). On a
terminal without one, and inside a Herdr pane, the row is a placeholder: `▣
image · plot.png · image/png · 1200×700 · 84 KB · o opens · v braille
preview`, where `o` hands the bytes to the platform opener the `loom ui
--open` path already has, and `v` draws a braille preview through
`etui/braille` in the same box. The placeholder is the row every host draws
today (`[image image/png]`, `UserImage` at
`session_view/transcript_lines.gleam:2300` and `ToolResultImage` at
`session_view/transcript_lines.gleam:2958`); the concept gives it the
figures and the keys.

**Detection without guessing.** The terminal is asked, not inferred from
`TERM`. The kitty graphics protocol (kitty, Ghostty, WezTerm) answers a query
placement (`a=q`) with an `OK` or an error response, so the launcher sends
one query with a short deadline after the alternate screen is entered and
treats only a well-formed response as support; iTerm2 declares itself in
`TERM_PROGRAM` and takes OSC 1337 without a query; sixel support is read from
the primary device attributes reply (`;4`). Inside Herdr (`configure`,
`tui/herdr.gleam:209`, gates on `HERDR_ENV`) the query is not sent, since
0.9.3 removed the pane graphics API and an escape that reaches the pane is
not guaranteed to reach the screen. Under tmux the query is sent through the
passthrough wrapper and the reply, if any, is the proof; no reply within the
deadline is no support. The answer is read once at launch like the palette
(`detect`, `tui/appearance.gleam:46`) and never during the step.

**Scrollback and resize.** An image belongs to its row (`Image`,
`session_view/transcript_image.gleam:29`, keyed by the row's block). It is
placed when its reserved cells are on screen and deleted when they are not,
by the image's id, so a scrolled-off image leaves no stale pixels and a row
that scrolls back in is placed again from the same bytes. A resize re-lays
the rows, which recomputes the box's cells, and the placement is redone with
the new cell size; a terminal that reports no cell pixel size gets the
placeholder. The frame cache holds the reserved cells as ordinary cells, so
etui's frame diff leaves them alone; the placement escapes are emitted after
the frame as a separate layer.

**The etui item.** Loom's terminal draws through etui, and etui has braille
graphics and OSC 8 links but no image protocol. The slicing plan makes "an
image protocol in etui" its own item: a graphics layer API (reserve cells,
place an image by id over them, delete by id, flush after the frame), the
kitty, iTerm2 and sixel encoders, and the capability query. It is an etui
change, not a Loom one, and the Loom side is only the placeholder row, the
keys and the layer calls.

## 10. Per-workspace layout memory

What is remembered: whether the panel is shown, which tab is active, and
whether the sessions column is pinned. Not remembered: the focused strand (a
launch shows `main`, as the web ruling has it), the cursor, the scroll
position, or the viewed session.

Where: the terminal's state root (`state_directory`,
`tui/bootstrap.gleam:676`, `~/.loom` by default), in `layout/<digest>.json`,
where the digest is of the canonical workspace path from `Context`
(`tui/workspace.gleam:16`). The daemon is not involved: the web view keeps the
same state in the browser's storage, and the terminal's equivalent of the
browser is its own state root. One file per workspace is also what makes the
file easy to delete (`/layout reset`).

How it is read and written, within the rules the terminal already has:

- **Read outside the step.** The launch path reads the file beside the
  workspace discovery it already does before the loop, and the attachment
  worker reads the file for a session's workspace when it resolves the route,
  delivering it with `Adopted`, the way the workspace context travels today.
  The step reads no file.
- **Written as an effect.** A toggle queues `SaveLayout(path, layout)` on the
  outbox (`Effect`, `tui/effect.gleam:56`), and the runtime writes it after
  the step; a failed write is a footer notice, never a failure of the toggle.
- **Decoded totally.** A missing, unreadable or malformed file is the default
  layout (panel shown from 140 columns on first launch, Strands, column
  unpinned); an unknown tab name is Strands. The file is the operator's own
  and reaches no wire.

## 11. Key bindings, checked against today

The composer's keys today are in `update_conversation_key`
(`tui/interaction.gleam:1273`) and `update_main_key_composing`
(`tui/interaction.gleam:1118`); the strip's in `update_strip_key`
(`tui/interaction.gleam:1089`); the inspector's keys include `1` to `4` for
its details (`tui/interaction.gleam:714`); the diff, summary, context and
queue surfaces have their own handlers (`update_diff_key` at
`tui/interaction.gleam:2414`, `update_summary_key` at
`tui/interaction.gleam:2465`, `update_context_key` at
`tui/interaction.gleam:2571`, `update_queue_key` at
`tui/interaction.gleam:2030`); `Ctrl+C` is global (`update_normal_key`,
`tui/interaction.gleam:495`).

| Key | Today | In this concept | Collision |
|---|---|---|---|
| `Enter`, `Tab`, `Esc` in the composer | send; queue/steer; interrupt (`toggle_submission_mode` at `tui/interaction.gleam:1611`) | unchanged | none; `Esc` is never "back to main" |
| `←` on an empty composer | opens the picker (`open_session_selector`, `tui/interaction.gleam:1649`) | unchanged; with the sessions column pinned it focuses the column instead | none |
| `↓` on an idle composer | enters the strip (`down_from_composer`, `tui/interaction.gleam:1490`) | enters the Strands list, which is the strip when the panel is hidden | none |
| `↑` | prompt history (`navigate_history`, `tui/interaction.gleam:1511`) | unchanged | none |
| `Shift+Tab` | toggles the rail (`toggle_agent_rail`, `tui/interaction.gleam:1612`) | toggles the panel | same key, wider meaning |
| `Ctrl+O`, `F2` | open the agent workspace (`open_agents`, `tui/interaction.gleam:1385`) | the panel on Strands with the keyboard; the workspace when the panel cannot fit | same habit |
| `Ctrl+g` | details (`toggle_details`, `tui/interaction.gleam:1560`) | unchanged, and expands counted rows and code-mode boxes | none |
| `Ctrl+D` while the diff is shown | diff navigator focus (`tui/interaction.gleam:1382`, the `worktree` focus) | focus the Changes tab | same |
| `Alt+q` | queue inspector (`open_queue`, `tui/interaction.gleam:1380`) | unchanged | none |
| `Alt+<char>` | interrupt and insert (`interrupt_and_insert`, `tui/interaction.gleam:1691`) | unchanged; the concept adds no Alt chord | none, by design |
| `PgUp` `PgDn` | scroll the transcript (`scroll_reading_panel`, `tui/interaction.gleam:1586`) | unchanged; scroll the panel while it has focus | none |
| `End` on an empty composer | back to the tail (`scroll_transcript`, `tui/interaction.gleam:1680`) | unchanged | none |
| `1`–`4` | inspector details, inspector focused | tabs, panel focused; the inspector's details become the detail's sections, `←`/`→` | moved within one focus owner |
| `[` `]` | select a message or note in the inspector | unchanged inside `MESSAGES` and `NOTES` | none |
| `x`, `a`, `n`, `p`, `r` | strip and inspector keys | the same letters in the Strands list | none |
| `Ctrl+B`, `Ctrl+Alt+B` | — | not used | tmux prefix; avoided |
| `/layout …` | — | pin, unpin, reset | new slash command |

The approval block's `1`, `2`, `3` select a choice while the block has the
keyboard, as `↑`/`↓` do today; `Enter` confirms and `Esc` defers, unchanged.
No single key sends a decision.

## 12. What each region needs, and where it comes from

| Region | Data | Exists | Where |
|---|---|---|---|
| Header | session title, workspace, model | yes | `render_header`, `tui/render.gleam:520` |
| Timeline gutter | each row's strand and hue | derivable | `pieces` (`session_view/turns.gleam:348`), `hue` (`session_view/turns.gleam:300`); new hue constants in `tui/theme.gleam` |
| Counted repeated rows | consecutive identical calls and errors | derivable | the grouping in `project` (`session_view/tool_activity.gleam:55`) gains a run-length fold; shared with the web view |
| Harness notes | `[loom]`-prefixed inputs, hook and job notices | partly | `harness_message_lines` (`session_view/transcript_lines.gleam:2628`) recognises advisor frames; `memory_context_lines` (`session_view/composer.gleam:356`) the memory context; the `[loom]` job and hook notices need the same recogniser extended, no wire change |
| Strands tab, strip, workspace list | one row per strand | yes | `lines` (`session_view/agent_roster.gleam:355`), `Line` (`session_view/agent_roster.gleam:84`), `status_line` (`session_view/strand_card.gleam:45`), `status_mark` (`tui/agents.gleam:1369`) |
| Strand detail | task, now, update, pending, recent, approvals | yes | `Row` (`session_view/agent_view.gleam:79`) |
| Strand detail: messages out | sends with state | yes | `Item` (`session_view/agent_messages.gleam:52`) |
| Strand detail: messages in, inbox | received messages, unread count | no | section 9.2; a strand origin on the admitted message and an inbox read need a protocol change |
| Strand detail: cache | the cache outlook words | yes | `outlook_label` (`session_view/cache_miss.gleam:435`), today in `cache_outlook` (`tui/model.gleam:472`) |
| Nudge count on the advisor row | pending nudges | yes | `Board` (`session_view/advisor_pending.gleam:51`), `nudges` (`session_view/model.gleam:236`) |
| Changes tab | worktree observation, navigator, patch | yes | `State` (`session_view/worktree_view.gleam:98`), `layout` (`tui/diff_panel.gleam:33`), with `fold` (`session_view/changes_view.gleam:210`) as the labelled fallback |
| Trace tab, code-mode box | program, result, status | yes | `code_mode_program` (`session_view/transcript_lines.gleam:3574`), `execution_value` (`tools/codemode.gleam:1505`) |
| Trace tab, code-mode box | the capability call list | no | protocol change (section 9.1, with #656) |
| Session tab: goal | the goal board | yes | `row` (`session_view/goal_view.gleam:553`), `goal` (`session_view/model.gleam:248`) |
| Session tab: jobs | the live jobs board | yes | `jobs` (`session_view/session_summary.gleam:99`), `lines` (`session_view/live_jobs.gleam:107`) |
| Session tab: schedules | the schedule rows | partly | `append_schedules` (`session_view/event_fold.gleam:607`) turns the `SchedulesSnapshot` rows into transcript lines and keeps no board; a `Shared.schedules` fold of the same `ScheduleRow` (`session_view/protocol.gleam:83`) is a `session_view` change, no wire change |
| Session tab: viewers | the presence roster | yes | `viewers` (`session_view/session_summary.gleam:122`) |
| Session tab: cost, context | usage, context estimate | yes | `usage` (`session_view/model.gleam:365`), `money` (`session_view/transcript_lines.gleam:4439`), `footer` (`session_view/context_view.gleam:414`) |
| Session tab: last completion | completion evidence | yes | `lines` (`session_view/completion_summary.gleam:514`) |
| Sessions column, picker | rows, activity | yes, minus an age | section 1.1 |
| Approval block | the exact escalation | yes | `approvals` (`session_view/model.gleam:354`), `render` (`tui/approval_panel.gleam:286`) |
| Todo line | the strand's board | yes | `height` (`tui/todo_panel.gleam:50`), `todo_boards` (`session_view/model.gleam:309`) |
| Scrollback position | rows above the tail | yes | `reading_history` (`tui/model.gleam:1340`), `viewport_backlog` (`tui/model.gleam:756`) |
| Images | bytes, type, pixel size | partly | `Image` (`session_view/transcript_image.gleam:29`) holds the bytes and type; the pixel size is decoded client-side from the PNG, JPEG, GIF or WebP header, no wire change; drawing needs etui |
| Layout memory | the three preferences | new | section 10 |

## 13. Every frame

All frames at the sizes claimed; dark and light are the same grid.

| Name | Size | Dark | Light | Grid |
|---|---|---|---|---|
| picker-120 | 120×40 | [png](C-fable-picker-120-dark.png) | [png](C-fable-picker-120-light.png) | [txt](C-fable-picker-120.txt) |
| picker-120-needs | 120×40 | [png](C-fable-picker-120-needs-dark.png) | [png](C-fable-picker-120-needs-light.png) | [txt](C-fable-picker-120-needs.txt) |
| picker-120-empty | 120×40 | [png](C-fable-picker-120-empty-dark.png) | [png](C-fable-picker-120-empty-light.png) | [txt](C-fable-picker-120-empty.txt) |
| picker-80 | 80×24 | [png](C-fable-picker-80-dark.png) | [png](C-fable-picker-80-light.png) | [txt](C-fable-picker-80.txt) |
| agents-120 | 120×40 | [png](C-fable-agents-120-dark.png) | [png](C-fable-agents-120-light.png) | [txt](C-fable-agents-120.txt) |
| agents-120-failed | 120×40 | [png](C-fable-agents-120-failed-dark.png) | [png](C-fable-agents-120-failed-light.png) | [txt](C-fable-agents-120-failed.txt) |
| agents-120-empty | 120×40 | [png](C-fable-agents-120-empty-dark.png) | [png](C-fable-agents-120-empty-light.png) | [txt](C-fable-agents-120-empty.txt) |
| agents-80 | 80×24 | [png](C-fable-agents-80-dark.png) | [png](C-fable-agents-80-light.png) | [txt](C-fable-agents-80.txt) |
| wide-default | 200×50 | [png](C-fable-wide-default-dark.png) | [png](C-fable-wide-default-light.png) | [txt](C-fable-wide-default.txt) |
| wide-collapsed | 200×50 | [png](C-fable-wide-collapsed-dark.png) | [png](C-fable-wide-collapsed-light.png) | [txt](C-fable-wide-collapsed.txt) |
| standard-default | 120×40 | [png](C-fable-standard-default-dark.png) | [png](C-fable-standard-default-light.png) | [txt](C-fable-standard-default.txt) |
| standard-focus | 120×40 | [png](C-fable-standard-focus-dark.png) | [png](C-fable-standard-focus-light.png) | [txt](C-fable-standard-focus.txt) |
| standard-changes | 120×40 | [png](C-fable-standard-changes-dark.png) | [png](C-fable-standard-changes-light.png) | [txt](C-fable-standard-changes.txt) |
| standard-trace | 120×40 | [png](C-fable-standard-trace-dark.png) | [png](C-fable-standard-trace-light.png) | [txt](C-fable-standard-trace.txt) |
| standard-session | 120×40 | [png](C-fable-standard-session-dark.png) | [png](C-fable-standard-session-light.png) | [txt](C-fable-standard-session.txt) |
| standard-agents | 120×40 | [png](C-fable-standard-agents-dark.png) | [png](C-fable-standard-agents-light.png) | [txt](C-fable-standard-agents.txt) |
| standard-errors | 120×40 | [png](C-fable-standard-errors-dark.png) | [png](C-fable-standard-errors-light.png) | [txt](C-fable-standard-errors.txt) |
| narrow-default | 80×24 | [png](C-fable-narrow-default-dark.png) | [png](C-fable-narrow-default-light.png) | [txt](C-fable-narrow-default.txt) |
| narrow-panel | 80×24 | [png](C-fable-narrow-panel-dark.png) | [png](C-fable-narrow-panel-light.png) | [txt](C-fable-narrow-panel.txt) |
| narrow-agents | 80×24 | [png](C-fable-narrow-agents-dark.png) | [png](C-fable-narrow-agents-light.png) | [txt](C-fable-narrow-agents.txt) |
| codemode-today-120 | 120×40 | [png](C-fable-codemode-today-120-dark.png) | [png](C-fable-codemode-today-120-light.png) | [txt](C-fable-codemode-today-120.txt) |
| codemode-calls-120 (needs protocol-change) | 120×40 | [png](C-fable-codemode-calls-120-dark.png) | [png](C-fable-codemode-calls-120-light.png) | [txt](C-fable-codemode-calls-120.txt) |
| codemode-80 | 80×24 | [png](C-fable-codemode-80-dark.png) | [png](C-fable-codemode-80-light.png) | [txt](C-fable-codemode-80.txt) |
| messages-today-120 | 120×40 | [png](C-fable-messages-today-120-dark.png) | [png](C-fable-messages-today-120-light.png) | [txt](C-fable-messages-today-120.txt) |
| messages-origin-120 (needs protocol-change) | 120×40 | [png](C-fable-messages-origin-120-dark.png) | [png](C-fable-messages-origin-120-light.png) | [txt](C-fable-messages-origin-120.txt) |
| peers-120 | 120×40 | [png](C-fable-peers-120-dark.png) | [png](C-fable-peers-120-light.png) | [txt](C-fable-peers-120.txt) |
| image-placeholder-120 | 120×40 | [png](C-fable-image-placeholder-120-dark.png) | [png](C-fable-image-placeholder-120-light.png) | [txt](C-fable-image-placeholder-120.txt) |
| image-rendered-120 | 120×40 | [png](C-fable-image-rendered-120-dark.png) | [png](C-fable-image-rendered-120-light.png) | [txt](C-fable-image-rendered-120.txt) |
| image-placeholder-80 | 80×24 | [png](C-fable-image-placeholder-80-dark.png) | [png](C-fable-image-placeholder-80-light.png) | [txt](C-fable-image-placeholder-80.txt) |

The "before" captures of today's client: the picker at
[120×40](C-fable-before-picker-120-all.png), with the [Needs you
filter](C-fable-before-picker-120-needs.png), and at
[80×24](C-fable-before-picker-80-all.png); the agent workspace at
[120×40](C-fable-before-agents-120-workspace.png), its [Messages
tab](C-fable-before-agents-120-messages.png), and at
[80×24](C-fable-before-agents-80-workspace.png); and the strip with the
keyboard in it at [120×40](C-fable-before-agents-120-strip.png) and
[80×24](C-fable-before-agents-80-strip.png). Each has a `.txt` beside it.

## 14. Slicing into reviewable pull requests

Each is one feature, builds and passes `make check` on its own, and the ones
that change what the terminal draws are checked with the `gleam dev agents`
fixture and a live drive at 120×40 and 80×24, with frames attached, because
the look is the point. The owner's two views go first.

1. **The session picker.** The title-row filter tabs, aligned columns, the
   `~` paths, the identity moved to the pane, the never-empty pane, the 80×24
   preview strip, the empty state. `tui/session_selector` only; no data
   change. Proof: `session_selector_test` goldens at both sizes; the empty and
   filtered states.
2. **The agent workspace.** One-row strands on aligned columns with the
   suffix-keeping name, the counted title, the card detail with `TASK`, `NOW`,
   `MESSAGES` (sent, from `agent_messages`), `INBOX` (pending approvals and
   held inputs), `RECENT`, the failed and empty states, the 80×24 window.
   `tui/agents` and `tui/agent_strip` share the row renderer. Proof:
   `agent_workspace_test` goldens; the fixture at both sizes.
3. **Counted rows and harness notes.** The run-length fold for identical
   consecutive calls and errors in `session_view/tool_activity`, and the
   `[loom]` notice recogniser beside the memory-context one. Shared with the
   web view. Proof: `tool_activity` and `transcript_lines` tests; a replay of
   the owner's `agent_wait ×15` recording shape.
4. **The approval block.** The dock form with numbered choices and the reason
   line, same capture and same confirm rule. Proof: `approval_presentation_test`;
   a drive with two pending approvals.
5. **The panel shell.** One right column with four tabs, `Shift+Tab`, the
   keyboard owner, the strip yielding while Strands shows; Strands and Changes
   only, moving the rail and the diff pane in; the narrow form over the
   transcript. Proof: layout tests at 80, 100, 120, 180 and 200 columns;
   `hit_area` tests for mouse.
6. **The Session tab**, with the schedules fold in `session_view`, and the
   `/summary`, `/context` and `/goal` routes into it.
7. **The timeline gutter and strand hues.** Hues in `tui/theme` and
   `tui/appearance`, the per-row hue beside the anchors, the `●` crossings, and
   mouse focus on a name cell. Proof: `row_cache_test`, `appearance_test` for
   light values, a `--demo` frame.
8. **Layout memory.** `tui/layout_memory` with the total decoder, the
   `SaveLayout` effect, the reads in the launcher and the attachment worker,
   `/layout`. Proof: decoder tests over malformed input; a drive across two
   workspaces.
9. **Code mode boxes and the Trace tab**, possible today: the titled box
   with the failure or the source preview, the value row, the enforcement
   summary. Then, as a `protocol-change/NNN.md` with #656, the per-call
   record on the result, and the call tree drawn from it.
10. **Strand messages.** The sent rows, possible today. Then a
    `protocol-change/NNN.md` for a strand origin on the admitted message and
    a read-only inbox count, and the received rows drawn from them.
11. **Peer rows**, the `◇ peer` heading restyled with the hue and the
    `authenticated origin` words, and the test that no body text produces it.
12. **The image placeholder row** with `o` and `v`, and the pixel-size decode.
13. **An image protocol in etui** (sibling repository): the graphics layer
    API, the kitty, iTerm2 and sixel encoders, the capability query with a
    deadline, and the Herdr and tmux rules. Then the Loom side places images
    over the reserved cells.
14. **The sessions column** at ≥180 columns, drawing the picker's rows with
    the activity poll running only while the column has focus.

Slices 1 to 4 need no decision from the owner beyond the pick. Slices 9 and
10 each have a first half that is possible today and a second half behind a
protocol change; slice 13 is sibling-repository work. Those halves are last.

## 15. Open questions for the owner

1. **Should the panel be open by default on first launch at 140 columns and
   above?** Recommended: yes, since the changes pane opens itself at that width
   today and the memory keeps whatever the operator does next.
2. **Should `Esc` while the panel has the keyboard also hide it, or only
   return the keyboard?** Recommended: only return the keyboard; `Shift+Tab`
   hides. One key, one meaning.
3. **Do you want a row cursor over the transcript**, so that `●` crossings are
   reachable with arrows and `Enter`? Recommended: no for this revamp; the
   Strands list is the keyboard's timeline and a transcript cursor is a third
   keyboard owner with anchor bookkeeping.
4. **Should `1`–`3` in the approval block select or confirm?** Recommended:
   select, with `Enter` to confirm, as today's arrows do, so no decision is one
   keystroke.
5. **Should the agent workspace stay a full overlay when the panel fits?**
   Recommended: yes, `Ctrl+O` opens the panel on Strands when it fits and the
   overlay when it does not; a second `Ctrl+O` from the panel opens the
   overlay for a wider detail. The list and detail are one renderer either
   way.
6. **Strand hues: five, by position?** Recommended: five, by position among
   captured strands as `turns.hue` does, never by name, and the advisor keeps
   the terminal's violet rather than A2's amber.
7. **Layout memory location: the state root, or a `.loom/` file in the
   workspace?** Recommended: the state root, which keeps the repository clean
   and the file private.
8. **The code-mode call list: record calls on the result now, timing later,
   as one protocol change in two steps?** Recommended: yes; the untimed list is
   what both hosts need first, and the record does not exist today.
9. **Received strand messages: ship the sent rows now and propose the strand
   origin as one protocol change with the inbox count?** Recommended: yes;
   nothing client-side can attribute a received message honestly today.
10. **Images: is Herdr worth a text-only rule, or should the terminal still
    send the query inside a Herdr pane?** Recommended: text only inside Herdr
    until Herdr documents passthrough; a query that reaches a pane and not the
    screen is a guess.
