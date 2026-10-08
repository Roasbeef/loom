# Terminal revamp, concept B: one column, a drawer, and a frame around the input

**Status: proposed, one of three concepts for issue #655, for the owner's pick.
No code changes.**

The idea in one sentence: the transcript stays one column at every width,
everything A2 puts in side panels lives in one right-hand drawer that docks
beside the transcript only when the window can spare the width and takes the
transcript's place when it cannot, and the status that today sits in a header
and a footer moves onto the frame around the input.

The two views the owner named as sloppy, the session picker and the agent
workspace, come first in this note and first in the slicing plan. They are
restyles of what exists, need no protocol change, and are useful whichever
layout concept is picked.

An earlier draft of this concept moved `←` to open the strands view after the
Codex brief. It is back where it is today: `←` from an empty composer opens
the session picker, and `↓` enters the agent strip.

All frames are character grids at the widths they claim. Each is committed as
a `.txt` file, rendered in the terminal's palette by
[`B-opus.html`](B-opus.html), and screenshotted in light and dark. The image
index is in section 14.

## 1. The session picker

### Before

![Today's picker at 120×40](B-opus-before-picker-120x40-dark.png)

[before, 120×40](B-opus-before-picker-120x40.txt) ·
[before, 80×24](B-opus-before-picker-80x24.txt) ·
[light](B-opus-before-picker-120x40-light.png) ·
[80×24 png](B-opus-before-picker-80x24-dark.png)

The before frames were rendered from `render` at `tui/session_selector.gleam:815` with six fixture sessions, because `--demo` has no daemon and
answers `←` with "daemon control is unavailable". What is wrong with it:

- **Alignment.** A row is the name, then ` · ` and the short identity, so the
  identity starts at a different column on every row. The `current` marker is
  right-aligned on one row only. A saved or blocked row appends its state in
  brackets after the name (`[saved]`, `[recovery blocked]`), so state has no
  column either.
- **Truncation and wrapping.** Workspace headings print the full absolute
  path including the home directory. The detail pane wraps that path in the
  middle of a word (`roasbe` / `ef/loom`).
- **Empty names.** An unnamed session draws as a glyph, two spaces, a
  separator and an identity (`◌  · 01a07d75-0000`).
- **Hierarchy.** The detail pane puts each label on its own line above its
  value, so four facts take sixteen rows, and labels and values have the same
  weight.
- **Frame.** The picker is a floating box centred over the transcript, as
  tall as its content, so the transcript shows above and below it and its
  height changes as the filter changes.
- **80×24.** Each session takes two rows (name, then state and identity), so
  the list is cut after the first row of the second workspace, and the help
  line is cut with an ellipsis.
- **Empty and loading states.** An empty filter says "No saved sessions.
  Press n to create one", which is wrong when sessions exist under another
  filter. A resident session whose activity read has not answered shows `◌`
  and the word `resident`, which does not say that the client is still
  asking.

### After

![Picker at 120×40](B-opus-picker-120x40-dark.png)

[120×40](B-opus-picker-120x40.txt) ·
[80×24](B-opus-picker-80x24.txt) ·
[empty and loading](B-opus-picker-empty-120x40.txt)

![Picker at 80×24](B-opus-picker-80x24-dark.png)
![Picker empty and loading states](B-opus-picker-empty-120x40-dark.png)

- The picker takes the whole body, above the composer frame, so its size
  does not move with its content. The composer frame stays drawn and says
  that the list owns the keys.
- One row per session: glyph, name, state words, marker, each in a column.
  Names longer than the column lose their middle and keep their end, which is
  where `· herdr-update` or an identity suffix tells two rows apart.
- Workspace headings shorten the home directory to `~`. Paths are cut in the
  middle at a path separator, never wrapped.
- An unnamed session reads `unnamed · 01a07d75`, in the quiet colour.
- The detail pane is a key and value list with labels in the quiet colour at
  a fixed width: strands, last run, model, workspace, session, created.
- At 80×24 rows stay one line, and the selected session gets a three-row
  preview under a rule at the bottom of the list.
- An empty filter names where the sessions are ("Needs you has 1 · Tab moves
  to it"). A row whose activity read has not answered reads `observing…`. A
  missing control connection is one red line with what to do.
- Keys are unchanged: `↑↓`, `Enter`, `Tab` filter, `l`, `n`, `r`, `d`, `a`,
  `←→` pages, `Esc`. A `?` at 80 columns shows the hints that do not fit.

### Data

Everything drawn is already in the control protocol. A row is
`Session` at `tui/daemon/protocol.gleam:438`: identity, workspace, name,
`created_at` and lifecycle. The state words and counts come from
`Activity` at `tui/daemon/protocol.gleam:342`: state, strands, working,
approvals, last outcome, last message and model, with up to four
`GlanceLine` at `tui/daemon/protocol.gleam:362` rows. The filter counts are
`counts` at `tui/session_selector.gleam:736`. "Created" uses `created_at`. A
"last active" column would need a new control field, which is a
protocol-change; this concept does not ask for one (question 6).

## 2. The agent workspace

### Before

![Today's agent workspace at 120×40](B-opus-before-agents-120x40-dark.png)

[before, 120×40](B-opus-before-agents-120x40.txt) ·
[before, 80×24](B-opus-before-agents-80x24.txt) ·
[light](B-opus-before-agents-120x40-light.png) ·
[80×24 png](B-opus-before-agents-80x24-dark.png)

Captured from `gleam dev agents dark` (six fixture agents) in a private tmux
session. `--demo` gives the same layout with three strands and every field
"unavailable". The view is `render_rail` at `tui/agents.gleam:324` beside
`render_inspection` at `tui/agents.gleam:347`. What is wrong with it:

- **Columns.** Each strand takes three rows (name, task, status) and a blank,
  so six strands need 24 rows and the list scrolls at 120×40. No row shows
  elapsed time or tokens, which the strip under the input does show.
- **Truncation.** The 34-cell rail cuts the task mid-word
  (`Integrate the agent workspace a…`) and cuts the status line from the left
  (`× Failed · …n-label check failed`), which removes the start of the reason.
- **Repetition.** `✓ Finished · Finished` repeats the state word. The strand
  list is drawn three times on one screen: the rail, the strip under the
  footer, and the counts in the header and footer.
- **Hierarchy.** Seven uppercase headings (TASK, CURRENT STATE, LATEST
  UPDATE, RECENT ACTIVITY, INPUT, IDENTITY) each own a line above a one-line
  value. The selected row is marked by a background band and `▸`, the viewed
  strand by `· to`, and the cursor in the strip by `›`, three marks for two
  ideas.
- **Raw data.** A pending approval's preview is escaped JSON
  (`fs_write · {"path":…,"content":…}`) wrapped wherever it falls.
- **Chrome.** A bordered box, a three-row hint block inside it, a second hint
  on the composer rule (`Tab writes · Enter opens agent`), a two-row goal and
  advisor band, a footer and the strip: 14 rows that are not the list or the
  detail.
- **80×24.** The workspace shows one strand, the name of its first heading
  (`TASK`) with no value under it, and then the hint block. The list is not
  visible at all.
- **Empty state.** In `--demo` the detail is six lines of "unavailable" for
  task, update, activity, input and model.

### After

![Agent workspace at 120×40](B-opus-strands-120x40-dark.png)

[many strands, 120×40](B-opus-strands-120x40.txt) ·
[failed strand with a long task](B-opus-strands-failed-120x40.txt) ·
[80×24](B-opus-strands-80x24.txt) ·
[empty, 80×24](B-opus-strands-empty-80x24.txt)

![A failed strand with a long task](B-opus-strands-failed-120x40-dark.png)
![Agent workspace at 80×24](B-opus-strands-80x24-dark.png)
![Agent workspace, one strand](B-opus-strands-empty-80x24-dark.png)

- **One row per strand, in columns:** glyph, name, doing, time, ctx. Names
  lose their middle, so `sub:adversarial-code-review-48f3` and `…-ec14` stay
  distinct; `doing` is cut at the end with `…` and never from the left.
- **Filter tabs with counts:** All, Needs you, Working, Failed, Done. This is
  the picker's own filter pattern and the Codex command center's "Needs you".
- **One selection mark.** `❯` and bold name mark the cursor. The viewed
  strand is the one the composer frame names; it is not marked again in the
  list.
- **A labelled detail** under a rule: a header row (glyph, name, status,
  time, ctx, model) with the detail tabs `1 Overview 2 Messages 3 Notes 4
  Collab` on its right, then `Task`, `Now`, `Inbox` as labelled rows, then
  two columns, `MESSAGES` and `RECENT TOOLS`.
- **Long text** wraps at word boundaries and folds after two rows with a count
  (`+2 lines · PgDn`). A failure is one labelled `Result` row with the reason
  in full.
- **An approval** is one line in words (`waiting for approval: fetch
  proxy.golang.org · a reviews`). The exact request stays in the approval
  panel, which is where it can be decided; `d` there shows the raw request.
- **80×24:** five list rows and a `+2 more` line, then four detail rows. The
  hint is one line.
- **Empty:** with only `main`, the list says what will appear there and the
  detail still fills in.

The keys stay: `Ctrl+O`, `F2` and `/agents` open it; `↑↓` select; `Enter`
opens the strand's transcript; `n` next attention; `a` approval; `x` stop;
`1`–`4` detail; `[` `]` and `o` in Messages; `PgUp` `PgDn` scroll the detail;
`Esc` returns. One change is proposed and left to the owner: `Tab` cycles the
filter, as it does in the picker, instead of moving the keyboard to the
composer (question 3).

When the drawer of section 4 is docked, this same view is its Strands tab, in
fewer columns.

### Data

- Name, status, task, activity, update, pending input, approvals, model and
  recent tools: `Row` at `session_view/agent_view.gleam:79`.
- Elapsed time and tokens: `Line` at `session_view/agent_roster.gleam:84`,
  which the strip already draws.
- The status words: `status_line` at `session_view/strand_card.gleam:45`; the
  Needs you count: `needing` at `session_view/strand_card.gleam:240`.
- Messages: `for_strand` at `session_view/agent_messages.gleam:167`, the
  verified sends the captures have seen. The heading says "seen in captures"
  because a message sent by a strand whose branch the client has not
  captured is not there. A complete inbox for a strand that is not on screen
  is not on the client wire. Protocol-change 056 gave code mode an `inbox`
  call; a client read would be a new read command and a protocol-change.
- Inbox count: `PendingInput` at `session_view/snapshot_view.gleam:126`.

No protocol change is needed for the view as drawn.

## 3. What changes from today, and why

| Today | Concept B | Why |
|---|---|---|
| Header row: brand, session, model, `Ctrl+g details` | removed; session name on the input frame's top rule | one row back at every size |
| `transcript / main` label | a breadcrumb row only when a strand other than `main` is focused | the frame already names the target |
| Footer of one to three rows (`footer_rows`, `tui/layout.gleam:517`) | the input frame's bottom rule: model › workspace › branch › ctx › cost, needs-you count on the right | up to three rows back; omp and Codex show this is enough |
| Status band under the composer rule | an activity line above the input frame | the spinner sits next to the thing it describes |
| Agent strip under the footer | kept, under the input frame, with the same keys | the owner's recordings show it is the part that works |
| 34-cell rail toggled by `Shift+Tab` (`body_layout` at `tui/layout.gleam:138`) and the 72-cell changes pane | one drawer with tabs; `Shift+Tab` docks and hides it | one side region instead of two that take turns |
| `/agents` workspace as a box | full body, or the drawer's Strands tab when docked | section 2 |
| Transcript rows | a three-cell strand gutter; repeated calls collapsed with a count; harness notices in the system voice | sections 6 and 9 |
| Todo panel up to a third of the body | one line below 40 rows; today's panel at 40 rows and taller | the panel cost six rows at 80×24 |

Row budget at 80×24 with two strands listed: today the transcript gets 14
rows ([today's capture](#today-at-8024)); concept B gives it 17 with a todo
line ([narrow frame](B-opus-narrow-80x24.txt)).

<a id="today-at-8024"></a>Today's 80×24 rows, from a `--demo` capture: header
1, `transcript / main` 1, transcript 14, composer rule 1, status 1, input 1,
divider 1, footer 2, strip 2.

## 4. The layout at each width

![Default, 200×50](B-opus-wide-200x50-dark.png)

**Wide, 200 columns and more** ([frame](B-opus-wide-200x50.txt)). The drawer
docks by default at 160 columns and wider, 60 cells wide, full height, on the
Strands tab. While Strands is showing in the drawer, the roster under the
input is not drawn, so the strand list is on screen once. Prose in the
transcript keeps a measure of 110 cells after the gutter; code, tables and
diffs may use the column's full width.

![Standard, 120×40](B-opus-standard-120x40-dark.png)

**Standard, about 120 columns** ([frame](B-opus-standard-120x40.txt)). One
column by default, with the roster under the input as today. `Shift+Tab`
docks the drawer at 38 cells, which leaves the transcript 81
([focus frame](B-opus-focus-120x40.txt)).

![Narrow, 80×24](B-opus-narrow-80x24-dark.png)

**Narrow, 80×24** ([frame](B-opus-narrow-80x24.txt)). The drawer never
docks. Opening it puts it in the transcript's place, above the input frame,
and `Esc` puts the transcript back ([drawer frame](B-opus-drawer-80x24.txt)).

![The drawer at 80×24](B-opus-drawer-80x24-dark.png)

**How columns collapse.** The drawer docks only if the transcript keeps at
least 80 cells, which is the rule today's changes pane follows at 68. Its
width is 30% of the window, between 38 and 60 cells. Below 119 columns it
cannot dock. There is no left column at any width (question 1): sessions stay
in the `←` picker, and a person running several sessions at once already has
them in tmux or Herdr panes, which is what the owner's recordings show.

![Drawer hidden at 200×50](B-opus-collapsed-200x50-dark.png)

**Side column collapsed** ([frame](B-opus-collapsed-200x50.txt)). With the
drawer hidden at 200 columns, the transcript keeps its 110-cell prose measure
and the roster returns under the input.

## 5. Which parts of A2 fit a character grid

| A2 | In a terminal | Concept B |
|---|---|---|
| Calm single timeline with a dot per row in the strand's hue | fits: one cell per row | the gutter (section 6) |
| Collapsible side columns | fits, but two side columns at 120 leave the transcript under 60 cells | one drawer that docks or replaces |
| Tabbed right panel: Strands, Changes, Trace, Session | fits | the drawer's tabs |
| Strand cards with a ring and one status line | a ring is not drawable in cells | a glyph, the name, the status line, and the cache outlook as `3m` |
| Strand focus from dots, tags and cards | dots are cells, not buttons; no hover | `Ctrl+T` timeline cursor, `Enter` on a row; clicks are additive |
| Breadcrumb with `All strands` and `Esc` | `Esc` already interrupts the active strand | breadcrumb with `↓ ⏎ main` |
| `⌘B`, `⌘⌥B` | terminals do not deliver `⌘`; `Ctrl+B` is tmux's prefix; `Ctrl+Alt+B` parses as `Unknown`; any `Alt` letter is read as Escape then the letter (`interrupt_and_insert` at `tui/submit.gleam:411`) | `Shift+Tab`, which already toggles the rail |
| Left session sidebar | costs 26 or more cells and duplicates the multiplexer | not drawn; the `←` picker |
| 180 ms width animation, shadows, rounded cards | no | none |
| Approval card in the dock | fits | today's bottom-anchored approval panel, unchanged in rules |
| Typing indicator | not on the wire | not drawn |
| Layout per workspace in `localStorage` | no browser | a file in the state root (section 8) |

## 6. Strand focus from the timeline

The transcript has a three-cell gutter: a space, a mark, a space. The mark is
`●` in the hue of the strand the row belongs to, `∴` for reasoning, `┆` for a
peer, `◇` for a harness notice, `×` for an error, and `→` or `←` for a strand
message. The hue comes from `hue` at `session_view/turns.gleam:294`. Under the
plain palette the marks still differ by glyph, and a crossing row names its
strand in words, so nothing depends on colour.

`Ctrl+T` moves the keyboard into the timeline: a cursor appears on the newest
row, `↑` `↓` move it, and `PgUp` `PgDn` scroll. `Enter` on a row that names
another strand (a spawn, a result, a nudge, a message, a wait) focuses that
strand through `submit.switch_active_strand`, the path `Enter` in the strip
already takes, so the draft is parked and the transcript, composer target and
badge change together. `o` on an image row opens the image (section 12).
`Esc` leaves the cursor. A click on a gutter mark does the same as `Enter` on
its row.

A focused strand shows a breadcrumb row at the top of the transcript, `ws ·
main ▸ sub:tests`, and on its right the way back, `↓ ⏎ main`. `↓` from an
empty composer while a strand other than `main` is focused puts the strip's
cursor on `main`, so `↓ Enter` returns. Today the cursor lands on the row after
the viewed strand; this is the one change to the strip's keys.

![A focused strand](B-opus-focus-120x40-dark.png)

[frame](B-opus-focus-120x40.txt)

The spawn row in `main`'s transcript carries a small tree of the strands it
started (`├ ? sub:tests Needs approval · 34s · 9k`). The rows themselves are
durable and cached by `tui/projection`, but the glyph, status and figures are
painted at frame time from `Line` at `session_view/agent_roster.gleam:84`, so
a status change repaints the frame without invalidating the row cache.

## 7. The drawer's tabs and keys

| Tab | Shows | Opened by |
|---|---|---|
| Strands | section 2, in the drawer's width | `Ctrl+O`, `F2`, `/agents`, `↓` into the list when docked |
| Changes | files and hunks from the session's own edits; `Enter` opens a file full width | `/diff` |
| Trace | the latest `code_mode` program: state, program, result, budget; calls once a call record exists | `/trace` (new) |
| Session | goal, jobs, schedules, viewers, context, cost, last completion, usage | `/summary` |

![Changes tab](B-opus-changes-120x40-dark.png)
![Trace tab](B-opus-trace-120x40-dark.png)
![Session tab](B-opus-session-120x40-dark.png)

[changes](B-opus-changes-120x40.txt) · [trace](B-opus-trace-120x40.txt) ·
[session](B-opus-session-120x40.txt)

With the drawer focused: `←` `→` switch tabs, `↑` `↓` select, `Enter` acts,
and `Esc` or `Tab` return to the composer. The Strands tab carries a badge
with the Needs you count. The drawer carries no decision control; an approval
is decided in the approval panel only, as today.

The Trace tab and the code-mode block of section 10 read the same data. The
call list in both needs a new wire record (section 10).

### Key bindings checked against today

| Key | Today | Concept B |
|---|---|---|
| `←` on an empty composer | session picker (`tui/interaction.gleam:1376`) | unchanged |
| `↓` on an empty composer | into the strip (`down_from_composer` at `tui/interaction.gleam:1490`) | unchanged; lands on `main` when another strand is focused |
| `Shift+Tab` | toggle the rail (`tui/interaction.gleam:1441`) | toggle the drawer, which replaces the rail |
| `Ctrl+O`, `F2` | open `/agents` (`open_agents` at `tui/interaction.gleam:1385`) | open Strands: full body, or focus the docked drawer |
| `Ctrl+T` | unbound | timeline cursor (new) |
| `Ctrl+G` | details everywhere | unchanged |
| `Ctrl+D` | changes navigator focus | focus the drawer on Changes |
| `Esc` | close the open surface, else interrupt | unchanged; never "back to all strands" |
| `Tab` on the composer | steer for one draft | unchanged |
| `Alt+q` | queue inspector | unchanged |
| `End` on an empty composer | jump to the latest row | unchanged; the reading bar names it |
| `1` `2` `3` in the approval panel | unbound | select a choice; `Enter` still confirms |
| `o` in the timeline cursor | unbound | open the image externally |
| `←` `→` in the drawer | unbound | switch tabs |
| `Tab` in the agent workspace | move the keyboard to the composer | cycle the filter (question 3) |

No new binding uses `Alt`, because the terminal reads `Alt` plus a letter as
Escape followed by the letter, or `Ctrl+B`, because tmux takes it.

## 8. Per-workspace layout memory

What is remembered: whether the drawer is docked, its active tab, and
whether the todo line is expanded. What is not: the focused strand and the
viewed session, which follow the web's rulings (a reload shows `main`, and
the session is the one the command line or the picker chose).

Where: one file, `terminal-layout.json` in the state root (`~/.loom` unless the
launch names another), holding a map from the repository root that
`tui/workspace` discovers to that workspace's layout, capped at 64
workspaces, the oldest dropped. It is read once before the loop, as the
workspace is, and decoded totally: a missing, malformed or unknown value
yields the defaults. A change is written by a new effect the runtime performs
after the step, with `simplifile`, which the package already uses
(`tui/recording.gleam:73`). Two terminals on one workspace race, and the last
write wins, which is acceptable for a preference. A replay reads no layout
and writes none, so it keeps the rule that a replay performs no outbound
effect.

The daemon is not used for this (question 8): the layout is presentation
only, a terminal on another machine may want another layout, and a daemon
record would need a new control command.

## 9. What each region reads

| Region | Data | Source today |
|---|---|---|
| Gutter hues | strand hue | `hue` at `session_view/turns.gleam:294` |
| Worked divider with failure count | the turn's steps | `divider` at `session_view/turns.gleam:1405`, plus a failure count from the steps' results |
| Collapsed repeats (`agent_wait ×15`) | consecutive identical calls | a new rule in `project` at `session_view/tool_activity.gleam:55`; no wire change |
| Collapsed repeated errors (`429 ×20`) | consecutive identical local lines | a fold in `session_view` over `Shared.transcript`; no wire change |
| Harness notices as system lines | the `[loom] ` prefix | recognised today only to bound the turn, `harness_injection_summary` at `session_view/composer.gleam:444`; the line builder still draws a User turn |
| Spawn tree, roster, Strands tab | status, words, time, tokens | `Line` at `session_view/agent_roster.gleam:84`, `chips` at `session_view/agent_roster.gleam:393` |
| Activity line | the active operation | `tui/layout` labels today (`active_status_label`) |
| Status rule: ctx | context estimate | `footer` at `session_view/context_view.gleam:414` |
| Status rule: cost | session total | `usage` at `session_view/model.gleam:365` |
| Status rule: needs you | approvals per strand | `needing` at `session_view/strand_card.gleam:240` |
| Strands tab: cache | outlook per strand | `outlook` at `session_view/cache_watch.gleam:120` |
| Changes tab | session edits | `fold` at `session_view/changes_view.gleam:210` |
| Session tab: jobs, viewers | jobs board, presence | `jobs` at `session_view/session_summary.gleam:99`, `viewers` at `session_view/session_summary.gleam:122` |
| Code mode block, Trace tab | program, status, result | `code_mode_program` at `session_view/transcript_lines.gleam:3574`, `code_mode_result_lines` at `session_view/transcript_lines.gleam:3817`; the call list has no data and needs a new wire record |
| Peer messages | authenticated origin | `PeerOrigin` at `core/message.gleam:43`, `peer_message_lines` at `session_view/transcript_lines.gleam:2633` |
| Strand messages | harness text frame | `frame_message` at `client/agency.gleam:1877`; not recognised by `session_view` today |
| Images | mime type and bytes | `Image` at `session_view/transcript_image.gleam:29` |

Every row above is either drawn today or a change inside `session_view` or
`tui`, except two: the code-mode call list (a new wire record, by protocol-change) and an
origin on local strand messages (question 5).

## 10. Code mode

Two sets of frames, because only one can be drawn from what the client
receives.

**Drawable today** ([120×40](B-opus-codemode-today-120x40.txt) ·
[80×24](B-opus-codemode-today-80x24.txt)):

![Code mode today at 120×40](B-opus-codemode-today-120x40-dark.png)
![Code mode today at 80×24](B-opus-codemode-today-80x24-dark.png)

- A settled program is one row: `✓ code_mode probe_calc.gleam · completed ·
  result {"ok": true} · Ctrl+G`.
- A compile error is a titled block in the danger colour, `× code_mode ·
  compile error · probe_range.gleam`, with the error and the line it names,
  and a foot saying the program did not run.
- A running program is a titled block, `◐ running · check_subtract.gleam ·
  1.2s`, with the first lines of the program and a `RESULT` row that fills
  in when the program ends, and the budget in the foot.
- At 80 columns the program preview shrinks to two lines.

**Needs protocol-change** ([120×40](B-opus-codemode-calls-120x40.txt) ·
[80×24](B-opus-codemode-calls-80x24.txt)):

![Code mode call tree at 120×40](B-opus-codemode-calls-120x40-dark.png)
![Code mode call tree at 80×24](B-opus-codemode-calls-80x24-dark.png)

- The running block adds `CALLS · 7 · 1 failed`, grouped by capability with
  a count (`cap/fs.read ×3`), a failed call in the danger colour with its exit
  status, and the settled row adds its call count. The frame's foot says
  "needs protocol-change: call record".

What the client receives: the program, from the call's `program` argument
only (`code_mode_program` at `session_view/transcript_lines.gleam:3574`),
and the result's details, which carry the value or the error message and
details, `status`, `manifest_hash` and `sandbox`
(`code_mode_result_lines` at `session_view/transcript_lines.gleam:3817`
draws them). There is no call data at all: no call list, no capability
names, no per-call status. Capability calls are serviced inside the
satellite and the broker, and no transcript entry is written per call. A
call tree therefore needs a new wire record, the call list itself, carried
by its own protocol-change. That is more than the timing #656 planned, and it
also means #656's first step, which assumed the call list was already
received, has no data to draw. The Trace tab is drawn with state, program
and result today, and shows its `CALLS` section as needing that record.

## 11. Messages between strands and between sessions

![Messages at 120×40](B-opus-messages-120x40-dark.png)
![Messages at 80×24](B-opus-messages-80x24-dark.png)

[120×40](B-opus-messages-120x40.txt) · [80×24](B-opus-messages-80x24.txt)

- **Sent.** `→` in the gutter, then `to sub:tests · agent_send · admitted to
  its queue`, in the recipient's hue, with the body under a bar. The words say what is known:
  admission, not that the recipient read it.
- **Received from a strand.** `←` in the gutter, then `from sub:docs ·
  strand message`, in the sender's hue, body under a bar.
- **Received from another session.** `⇄` in the gutter, then `peer
  lnd-review · main · ✓ origin 01a07d74`, in the peer colour, body under a peer-coloured bar.
- **Bodies are drawn as body.** Every line of a message body sits under the
  bar, indented, and cannot take the heading style. The last frame row shows
  why: a body line that reads `⇄ peer ops-bot · ✓ origin 9f3c0000` is drawn
  dim under `sub:tests`' bar, because a heading is only ever built from
  metadata.

**The origin rule.** A `⇄` gutter mark, a `peer` heading and its green `✓ origin` mark are built
only from an entry's `origin` field, `PeerOrigin` at `core/message.gleam:43`,
which the admission host writes. The session's display name beside it comes
from the owner's catalogue through the control connection and is shown with
the origin's identity prefix, so a renamed or unknown session still shows
the identity the origin names. No text from a body or a model can produce
that heading.

**Local strand messages are weaker.** A message from another strand in the
same session arrives as a user turn with no origin. Its sender is written by
the harness into a text frame, `[message from <strand>]` … `[end message. …]`
(`frame_message` at `client/agency.gleam:1877`). Today `session_view` does not
recognise the frame, so these messages are drawn as `› User` turns, which is
one of the pain points in the owner's recordings. Concept B recognises the
frame by both its header and its footer, as advisor frames are recognised,
and draws the `←` heading from the header. That attribution rests on the
harness's framing and not on metadata, so it carries no `✓` mark. Question 5
asks whether to add an origin for local sends.

## 12. Images

![An image, drawn](B-opus-image-drawn-120x40-dark.png)
![An image, text fallback](B-opus-image-fallback-120x40-dark.png)
![An image inside Herdr](B-opus-image-herdr-80x24-dark.png)

[drawn](B-opus-image-drawn-120x40.txt) ·
[fallback](B-opus-image-fallback-120x40.txt) ·
[Herdr, 80×24](B-opus-image-herdr-80x24.txt)

Three cases:

- **A terminal that draws images** (kitty, Ghostty and WezTerm through the
  kitty graphics protocol; iTerm2 through OSC 1337). A labelled box reserves
  at most 12 rows by 60 columns under the row that owns the image, with the
  label `image 1 · image/png · 1200×700 · 84 KB` in its top rule and `o opens`
  in its foot, and the picture fills it.
- **A terminal that does not.** One line, `▣ image 1 · image/png · 1200×700 ·
  84 KB · o opens externally`, and a second line saying why. An optional
  braille preview is drawn under it in the quiet colour.
- **Herdr.** The same placeholder, with "inside Herdr: pane graphics are not
  passed through". Herdr removed its pane-graphics API in 0.9.3
  (`docs/next.md`, "Herdr integration corrections").

**Data.** The image's mime type and base64 bytes are
`Image` at `session_view/transcript_image.gleam:29`, already used by the web
page. The size is computed from the base64 length. The dimensions come from
the PNG `IHDR` chunk or the JPEG frame header, read with a bit-array pattern
in Gleam. A file name is not on the wire, so the label is `image n` of its
row. `o` writes the bytes to a private temporary file through an effect and
hands it to the platform opener the `loom ui` link already uses
(`opener_for` at `tui/view_link.gleam:83`).

**Detecting support without guessing.** At launch, before the loop, the
terminal sends the kitty graphics query (`ESC _G i=31,s=1,v=1,a=q,t=d,f=24;
AAAA ESC \`) followed by the primary device attributes request (`ESC [ c`). A
kitty-protocol reply that arrives before the attributes reply means support;
the attributes reply alone means none. iTerm2 does not answer that query, so
the terminal also sends `XTVERSION` (`ESC [ > 0 q`) and accepts OSC 1337 only
when the reply names iTerm2. No reply within 200 ms means none. The query is
skipped, and the answer is none, when `HERDR_ENV=1` is set, under `NO_COLOR`
or the plain palette, and inside tmux unless the reply comes back through it.
Environment variables such as `TERM_PROGRAM` are never trusted alone. Because
etui owns the terminal's input, the query and the reply parsing belong in
etui.

**Scrollback and resize.** The client draws on the alternate screen, so only
its own scrolling matters. With the kitty protocol the image is sent once and
placed with Unicode placeholder cells, which move with the text and survive
etui's frame diff like any other cell. OSC 1337 has no placeholder mode, so
an image is re-sent when its rows move, and only images inside the visible
window are sent. On resize the row count is recomputed from the cell size the
terminal reports (`ESC [ 16 t`) and the image is placed again.

The braille preview needs the image decoded to pixels. PNG needs an inflate,
which no allowed library offers in Gleam today, and the FFI rule makes a new
`.erl` file a last resort, so the preview is optional and last (question 7).

## 13. Today's pain points, and the inspiration

![Pain points fixed](B-opus-fixes-120x40-dark.png)
![Seven strands at 120×40](B-opus-multi-120x40-dark.png)
![Seven strands at 80×24](B-opus-multi-80x24-dark.png)
![An approval at 80×24](B-opus-approval-80x24-dark.png)

[fixes](B-opus-fixes-120x40.txt) · [multi, 120×40](B-opus-multi-120x40.txt) ·
[multi, 80×24](B-opus-multi-80x24.txt) ·
[approval, 80×24](B-opus-approval-80x24.txt)

### What we took from the owner's drives

| Pain point | Fix | Frame |
|---|---|---|
| Fifteen identical `✓ agent_wait · 2 subagents` rows | one counted row, `agent_wait · 2 subagents ×15 · 7m 30s`, updated in place | fixes |
| A background-job loss drawn as a `› User` turn | a dim `◇ loom · …` system line | fixes, multi |
| Twenty identical `http 429` errors | one counted row with the retry time | fixes |
| Two roster rows both `adversarial-code-revi…` | names cut in the middle, keeping the suffix | multi 80×24, strands 80×24 |
| Messages from other strands look like user turns | `←` and `→` message rows | messages |
| "6 agents · 5 working · 0 attention" in the footer | `1 needs you · 6 working` on the input frame | multi |
| No way back named while scrolled | `↑ reading · 38 rows below · End jumps to latest` | fixes |

Kept because the recordings show it working: the roster under the input with
name, action, time and ctx; the queue strip with `Alt+q`; Enter queues and Tab
steers. Taken from Claude Code: the roster under the input and the session
title on the input's rule. Taken from Codex: the Needs you count and filter
tabs (sections 1 and 2) and a full-width approval block with numbered
choices. The numbers select and never confirm, because the approval panel
selects nothing on opening and `Enter` alone decides. Taken from pi: the todo
as a fixed line above the input. Not taken: a full-screen command center for
strands that shows an empty preview pane, and a per-pane mascot header.

### What we took from omp

Taken: one column by default with panels on demand; the status merged into
the input's frame; the activity line above the input with its cancel key;
collapsed tool results with one expand key (`Ctrl+G`, since `Ctrl+O` opens
the strands view here); titled blocks for structured results, used for code
mode; sub-agents as a tree under the spawn row; dimmed reasoning with the
answer at full brightness; inline images where the terminal supports them.

Rejected: powerline separators, because they need a patched font, so the
rule uses `›`; a tinted background on every tool call, because at 80×24 a
transcript of tinted rows reads as stripes, so the tint is kept for the
person's own prompt, code and diffs; cost per sub-agent, because the session
keeps one cost total and no ledger per strand; diagnostics attached to a
write, since Loom has no language server.

### What we took from the Codex recording of 2026-09-30

Taken: a failure count in the header of a grouped tool summary (`▸ worked 48s
· 5 steps · 2 files · 1 failed`) with the failed child in the danger colour
and its exit status; session events as one dim system line. Not taken:
`←` for agents, by the owner's correction; a three-line diff preview under
every write, because it breaks the rule that a settled call keeps the row
count of its live form; a non-blocking choice menu, which Loom has no use for
yet.

## 14. Image index

| Frame | Grid | Light | Dark |
|---|---|---|---|
| Picker before, 120×40 | [txt](B-opus-before-picker-120x40.txt) | [png](B-opus-before-picker-120x40-light.png) | [png](B-opus-before-picker-120x40-dark.png) |
| Picker before, 80×24 | [txt](B-opus-before-picker-80x24.txt) | [png](B-opus-before-picker-80x24-light.png) | [png](B-opus-before-picker-80x24-dark.png) |
| Picker, 120×40 | [txt](B-opus-picker-120x40.txt) | [png](B-opus-picker-120x40-light.png) | [png](B-opus-picker-120x40-dark.png) |
| Picker, 80×24 | [txt](B-opus-picker-80x24.txt) | [png](B-opus-picker-80x24-light.png) | [png](B-opus-picker-80x24-dark.png) |
| Picker empty and loading | [txt](B-opus-picker-empty-120x40.txt) | [png](B-opus-picker-empty-120x40-light.png) | [png](B-opus-picker-empty-120x40-dark.png) |
| Workspace before, 120×40 | [txt](B-opus-before-agents-120x40.txt) | [png](B-opus-before-agents-120x40-light.png) | [png](B-opus-before-agents-120x40-dark.png) |
| Workspace before, 80×24 | [txt](B-opus-before-agents-80x24.txt) | [png](B-opus-before-agents-80x24-light.png) | [png](B-opus-before-agents-80x24-dark.png) |
| Workspace, many strands | [txt](B-opus-strands-120x40.txt) | [png](B-opus-strands-120x40-light.png) | [png](B-opus-strands-120x40-dark.png) |
| Workspace, failed and long | [txt](B-opus-strands-failed-120x40.txt) | [png](B-opus-strands-failed-120x40-light.png) | [png](B-opus-strands-failed-120x40-dark.png) |
| Workspace, 80×24 | [txt](B-opus-strands-80x24.txt) | [png](B-opus-strands-80x24-light.png) | [png](B-opus-strands-80x24-dark.png) |
| Workspace, empty | [txt](B-opus-strands-empty-80x24.txt) | [png](B-opus-strands-empty-80x24-light.png) | [png](B-opus-strands-empty-80x24-dark.png) |
| Default wide, 200×50 | [txt](B-opus-wide-200x50.txt) | [png](B-opus-wide-200x50-light.png) | [png](B-opus-wide-200x50-dark.png) |
| Standard, 120×40 | [txt](B-opus-standard-120x40.txt) | [png](B-opus-standard-120x40-light.png) | [png](B-opus-standard-120x40-dark.png) |
| Narrow, 80×24 | [txt](B-opus-narrow-80x24.txt) | [png](B-opus-narrow-80x24-light.png) | [png](B-opus-narrow-80x24-dark.png) |
| Focused strand | [txt](B-opus-focus-120x40.txt) | [png](B-opus-focus-120x40-light.png) | [png](B-opus-focus-120x40-dark.png) |
| Changes tab | [txt](B-opus-changes-120x40.txt) | [png](B-opus-changes-120x40-light.png) | [png](B-opus-changes-120x40-dark.png) |
| Trace tab | [txt](B-opus-trace-120x40.txt) | [png](B-opus-trace-120x40-light.png) | [png](B-opus-trace-120x40-dark.png) |
| Session tab | [txt](B-opus-session-120x40.txt) | [png](B-opus-session-120x40-light.png) | [png](B-opus-session-120x40-dark.png) |
| Drawer hidden, 200×50 | [txt](B-opus-collapsed-200x50.txt) | [png](B-opus-collapsed-200x50-light.png) | [png](B-opus-collapsed-200x50-dark.png) |
| Drawer at 80×24 | [txt](B-opus-drawer-80x24.txt) | [png](B-opus-drawer-80x24-light.png) | [png](B-opus-drawer-80x24-dark.png) |
| Seven strands, 120×40 | [txt](B-opus-multi-120x40.txt) | [png](B-opus-multi-120x40-light.png) | [png](B-opus-multi-120x40-dark.png) |
| Seven strands, 80×24 | [txt](B-opus-multi-80x24.txt) | [png](B-opus-multi-80x24-light.png) | [png](B-opus-multi-80x24-dark.png) |
| Pain points fixed | [txt](B-opus-fixes-120x40.txt) | [png](B-opus-fixes-120x40-light.png) | [png](B-opus-fixes-120x40-dark.png) |
| Approval, 80×24 | [txt](B-opus-approval-80x24.txt) | [png](B-opus-approval-80x24-light.png) | [png](B-opus-approval-80x24-dark.png) |
| Code mode today, 120×40 | [txt](B-opus-codemode-today-120x40.txt) | [png](B-opus-codemode-today-120x40-light.png) | [png](B-opus-codemode-today-120x40-dark.png) |
| Code mode today, 80×24 | [txt](B-opus-codemode-today-80x24.txt) | [png](B-opus-codemode-today-80x24-light.png) | [png](B-opus-codemode-today-80x24-dark.png) |
| Code mode call tree, needs protocol-change, 120×40 | [txt](B-opus-codemode-calls-120x40.txt) | [png](B-opus-codemode-calls-120x40-light.png) | [png](B-opus-codemode-calls-120x40-dark.png) |
| Code mode call tree, needs protocol-change, 80×24 | [txt](B-opus-codemode-calls-80x24.txt) | [png](B-opus-codemode-calls-80x24-light.png) | [png](B-opus-codemode-calls-80x24-dark.png) |
| Messages, 120×40 | [txt](B-opus-messages-120x40.txt) | [png](B-opus-messages-120x40-light.png) | [png](B-opus-messages-120x40-dark.png) |
| Messages, 80×24 | [txt](B-opus-messages-80x24.txt) | [png](B-opus-messages-80x24-light.png) | [png](B-opus-messages-80x24-dark.png) |
| Image drawn | [txt](B-opus-image-drawn-120x40.txt) | [png](B-opus-image-drawn-120x40-light.png) | [png](B-opus-image-drawn-120x40-dark.png) |
| Image fallback | [txt](B-opus-image-fallback-120x40.txt) | [png](B-opus-image-fallback-120x40-light.png) | [png](B-opus-image-fallback-120x40-dark.png) |
| Image in Herdr, 80×24 | [txt](B-opus-image-herdr-80x24.txt) | [png](B-opus-image-herdr-80x24-light.png) | [png](B-opus-image-herdr-80x24-dark.png) |

The palette is today's `tui/theme` for dark and `tui/appearance`'s light
mapping. Four colours are new and would be tokens in `tui/theme`: two strand
hues (`strand_2`, a teal, and `strand_3`, an olive), a peer colour distinct
from the advisor's violet, and a code background.

## 15. Slicing plan

Each pull request builds and passes `make check` on its own, adds snapshot
tests at 120×40, 80×24 and 40×12 through `tui/virtual_backend`, and is checked
by a drive in a real terminal.

1. **Session picker restyle.** `tui/session_selector` only: full body, the
   columns, `~` paths, middle cuts, the labelled detail, the 80×24 preview,
   the empty and loading words. No protocol change.
2. **Agent workspace restyle.** `tui/agents` and a column helper shared with
   `tui/agent_strip`: filter tabs, one row per strand, one selection mark,
   the labelled detail, word wrapping and folding, the approval in words. No
   protocol change. The `Tab` question is settled before this lands.
3. **Transcript hygiene in `session_view`.** Repeated calls and repeated
   errors collapse with a count; `[loom] ` notices draw in the system voice;
   local strand-message frames are recognised; the worked divider counts
   failures. The web view gets the same rows.
4. **The input frame.** Header and footer removed, the status rule, the
   activity line above, the roster under the frame, the todo line.
   `tui/layout` and `tui/render`.
5. **The gutter and the timeline cursor.** Marks, `Ctrl+T`, the breadcrumb,
   `↓` to `main`, clicks on marks, the live spawn tree.
6. **The drawer.** Dock or replace, `Shift+Tab`, Strands, Changes and
   Session tabs; the roster hides while Strands is docked.
7. **Layout memory.** The state-root file, its total decoder, and the save
   effect.
8. **Code-mode blocks.** Titled blocks for running and failed programs with
   their source and result, and the Trace tab with state, program and
   result. Works today.
9. **A code-mode call record.** A protocol-change adding the list of
   capability calls a program made, with each call's status, to the wire;
   then the `CALLS` section in the block and the Trace tab. Timing can ride
   on the same record or follow.
10. **Message presentation.** `→`, `←` and `⇄` rows with the origin rule, and
   a test that no body text can produce a `⇄` heading.
11. **Image placeholders.** The placeholder line, dimensions from headers,
    and `o` to open externally. Loom only.
12. **An image protocol in etui.** In the etui repository: the kitty graphics
    protocol with Unicode placeholders, OSC 1337, capability detection by
    query and reply, and the cell-size read. Not a Loom change.
13. **Drawn images in Loom**, on top of 12.

The shared-step decision, option (d) of #569 (whether the terminal moves onto
`step.update` with a pure callback before the revamp), is measured
separately and lands in `docs/review/terminal-option-d-2026-09-30.md`. This
concept does not decide it; slices 1, 2 and 10 do not depend on it.

## 16. Open questions for the owner

1. **Two columns at most, with no left session column?** Recommended: yes.
   Sessions stay in the `←` picker, and the multiplexer already shows several
   sessions at once.
2. **When does the drawer dock by default?** Recommended: at 160 columns and
   wider, with the remembered choice taking precedence.
3. **`Tab` in the agent workspace.** Recommended: `Tab` cycles the filter, as
   in the picker; `Esc` returns to the composer, which is what `Tab` does
   there today.
4. **Remove the header row?** Recommended: yes; the session name moves to the
   input frame's top rule.
5. **An origin for local strand messages?** Recommended: yes, a
   protocol-change adding a strand origin to local sends, so that `←` rows can
   carry the same kind of mark as peer rows. Until then, slice 3 recognises
   the harness frame and draws no mark.
6. **A "last active" column in the picker?** Recommended: not now; it needs a
   control-protocol field, and "Created" covers the common case.
7. **The braille image preview?** Recommended: leave it out until etui or a
   pure library can decode PNG.
8. **Layout memory in a state-root file rather than the daemon?**
   Recommended: the file.
9. **Hide the roster while the docked drawer shows Strands?** Recommended:
   yes, so the strand list is on screen once.
10. **One todo line below 40 rows?** Recommended: yes, with today's panel at
    40 rows and taller.

## 17. How the frames are made

The grids are written in a small markup by a script kept outside the
repository, which fails if any row is not exactly the frame's width or any
frame not exactly its height. The `.txt` files are its plain output, and
`B-opus.html` embeds the same rows with palette classes and renders one frame
alone for `?f=<id>&t=light|dark`, which is how the screenshots were taken
with headless Chrome. A frame can be changed and every output regenerated in
one run.
