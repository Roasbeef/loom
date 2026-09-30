# The terminal revamp, concept A: the transcript stays the screen

**Status: proposal, for the owner's sign-off.** One of three competing
concepts for [issue #655](https://github.com/Roasbeef/loom/issues/655). It
takes the web design ([concept A2](../web-design.md)) as the reference and
changes no production code. It was written against `main` at `f9927f7d9`.

| Concept | Idea |
|---|---|
| A (this note) | The transcript stays the screen at every width. A2's two sidebars become columns that dock only when the window has room and the operator has opened them, and the tabbed right panel is the same content as a sheet when it does not. Nothing new is shown by default below 200 columns. |

The design chooses one position on the question omp raises, one column or
three: **one column by default, columns by consent and by width.** Below 146
cells nothing docks two columns, below 117 nothing docks one, and at 80 by 24
the panel is a full-width sheet. The rest of this note follows from that
choice.

The source of truth for every frame is a plain-text grid,
`A-sonnet-<frame>.txt`, at its exact cell size. The PNGs are
renderings of those grids. `A-sonnet-gen.py` writes the grids
and `A-sonnet.html`, so a late adjustment is an edit to the
script and a rerun. The colours are the terminal's own palette
(`packages/tui/src/tui/theme.gleam`) and its light remapping
(`packages/tui/src/tui/appearance.gleam`). The PNGs render the glyphs with
the browser's fallback monospace font, so a few box-drawing joins are a pixel
off; the grids are exact.

## 1. What the terminal draws today

The frame is four rows stacked (`layout.layout`,
`packages/tui/src/tui/layout.gleam:76`): a one-row header, the body, the
composer, and the footer with the agent strip beneath it. The body holds the
transcript and, optionally, one side pane (`layout.body_layout`, line 94): the
34-cell agent rail, which is off by default and toggled by Shift+Tab, at 100
columns or more; or the `/diff` changes pane, up to 72 cells, at 140 or more.
The two share one slot, so opening the diff closes the rail. Below those
widths `/agents` and `/diff` take over the whole body. The footer carries the
model, the context estimate, the estimated cost and an attention count, and
the agent strip under it lists live strands (`agent_strip`).

These captures were taken from the built client in `--demo` at each size with
`tmux capture-pane`, so they are the real renderer. The demo has little
content; the structure is what matters. They are dark terminal captures only.

| Capture | Image | Grid |
|---|---|---|
| 200x50, `/diff` pane open | ![before, 200 wide](before-wide-diff.png) | [txt](before-wide-diff.txt) |
| 120x40 | ![before, 120 wide](before-120.png) | [txt](before-120.txt) |
| 120x40, rail toggled on | ![before, rail](before-120-rail.png) | [txt](before-120-rail.txt) |
| 120x40, `/agents` overlay | ![before, agents](before-120-agents.png) | [txt](before-120-agents.txt) |
| 80x24 | ![before, 80 wide](before-80.png) | [txt](before-80.txt) |

## 2. What translates from A2 and what does not

| A2 element | In the terminal | Why |
|---|---|---|
| Three columns | Yes, only at 146 cells and up; the right panel alone from 117 | Cells are coarse. The transcript needs about 72 cells to wrap prose and tool rows well (the diff pane already refuses to squeeze it under 68). |
| Collapsible sidebars, remembered per workspace | Yes | The state is presentation only. Section 6. |
| Tabbed right panel: Strands, Changes, Trace, Session | Yes, same four names | Each replaces something that exists: the rail and strip, the `/diff` pane, nothing (Trace), and the `/summary`, `/goal` and `/queue` surfaces. |
| Strand focus from the timeline | Yes, as inline tree rows plus a number-hint key | The terminal has no pointer-first timeline. Section 5. |
| Top bar with context and cost | No | The footer is the terminal's status region, is capped per section, and is tested at every width (`footer_fit_test`). Moving the figures would touch both. |
| Strand rings with a fill | No | A ring is an image. A status glyph, the name and `cache 3m` carry the same facts, and the owner ruled the ring shows the cache outlook only. |
| Per-row coloured timeline dots | Partly | One hue-coloured gutter cell (`▎`) marks rows where another strand crossed in. Main-strand rows stay blank. |
| Six strand hues | Three | The theme has cyan, violet and green beside amber and red, which carry operator action and failure. The name always appears beside the hue, so colour never carries identity alone. |
| Approve and Deny inside the panel | No | The owner's 2026-09-27 ruling stands. The terminal's approval dialog opens on its own and is modal; the panel says `Needs approval` and nothing else. |
| Theme toggle | No | The terminal follows the terminal's own background (`appearance.detect`). |
| Mouse-first clicks on dots and tags | Additive only | A click on a tag may focus a strand where the terminal reports mouse events. Every action also has a key. |

## 3. The layout at three widths

Dock widths are constants: the sessions column is 30 cells, the right panel
44 cells below 200 columns and 56 at 200 and up. The transcript takes the
rest and never drops under 72 cells; a column that would push it below that
does not dock, and the same content is offered as a sheet. Separators are one
cell each.

### 3.1 Wide, 200 columns and up

Both columns dock by default, as in A2: `30 + 1 + 112 + 1 + 56 = 200`. The
composer sits under the transcript only; the two side columns run down to the
footer. The footer is today's footer with one added hint.

![Wide, dark](A-sonnet-wide-dark.png)
![Wide, light](A-sonnet-wide-light.png)

Grid: [A-sonnet-wide.txt](A-sonnet-wide.txt).

**Left column, Sessions.** Workspaces as headings with a count, sessions under
them, the current one marked `▌` with one bar per live strand (`▮`). `●` is a
resident session and `○` a saved one. Bars show only for the session on
screen; other rows carry no attention count, following the web ruling that no
new data is fetched for them. It is today's session picker
(`session_selector`) docked: Left from an empty composer already opens it,
and docked it takes focus instead of opening an overlay.

**Right panel.** Four tabs; the Strands tab carries the count of strands that
need input. Section 4 describes each tab.

**Both columns collapsed** (focus mode) is the transcript alone with today's
strip under the footer:

![Focus, dark](A-sonnet-wide-focus-dark.png)

### 3.2 Standard, about 120 columns

Nothing is open by default. The screen is today's screen plus a breadcrumb row
and the gutter marks:

![Standard, dark](A-sonnet-standard-dark.png)

Opening the panel (F2 to F5, or Shift+Tab) docks it at 44 cells and hides the
strip, because the Strands tab says the same thing. `75 + 1 + 44 = 120`. The
sessions column does not dock here: `75 - 31` would leave 44. Left from an
empty composer opens the picker as today.

| Tab | Dark | Light |
|---|---|---|
| Strands | ![](A-sonnet-standard-strands-dark.png) | ![](A-sonnet-standard-strands-light.png) |
| Changes | ![](A-sonnet-standard-changes-dark.png) | ![](A-sonnet-standard-changes-light.png) |
| Trace | ![](A-sonnet-standard-trace-dark.png) | ![](A-sonnet-standard-trace-light.png) |
| Session | ![](A-sonnet-standard-session-dark.png) | ![](A-sonnet-standard-session-light.png) |

### 3.3 Narrow, 80 by 24

The default is today's screen. The top bar, transcript, composer, footer and
strip keep their rows. Columns never dock. F2 to F5 open the panel as a sheet
that replaces the transcript rows and leaves the composer and footer in
place, so a person can still type. Esc closes it.

| Frame | Dark | Light |
|---|---|---|
| Default | ![](A-sonnet-narrow-dark.png) | ![](A-sonnet-narrow-light.png) |
| Sheet, Strands | ![](A-sonnet-narrow-strands-dark.png) | ![](A-sonnet-narrow-strands-light.png) |
| Sheet, Changes | ![](A-sonnet-narrow-changes-dark.png) | ![](A-sonnet-narrow-changes-light.png) |

At 24 rows the composer takes four rows and the footer two; the sheet gets
the remaining fifteen and scrolls when a tab is longer.

## 4. The right panel and its tabs

Keys are in section 7. The tab bar is one row, the active tab on the raised
background, with a hairline under it. A row of key hints sits at the bottom of
the panel.

**Strands.** One two-row card per strand: status glyph, name and `cache 3m`
on the first row; `strand_card.status_line` on the second (`Working ·
code_mode`, `Needs approval`, `Finished 1m 12s`). Up and Down move a cursor
without retargeting the composer, the rule the strip already keeps. Enter
focuses the strand and opens its detail view in the same tab: model, context,
cache expiry, running time and the recent tools. The detail has no cost row,
because the session keeps one total and no ledger per strand (web-design.md,
section 9). With more than a few strands the header becomes a filter, taken
from Codex's command center: `All 6 · Needs you 1 · Working 4 · Done 1`, Tab
cycles it, and `n` jumps to the next strand that needs you.

![Six agents at 120 columns](A-sonnet-standard-multi-dark.png)

**Changes.** Files with counts and the first file's hunks, bounded by
`changes_view`. Where the terminal holds a worktree observation, which is the
owner's binding only, the tab shows it as `/diff` does today and labels the
source; otherwise it shows the session's own edits labelled "from this
session's edits". `/diff` opens this tab, and the separate 72-cell diff pane
(`diff_pane_width`) goes away. The full-width diff surface stays for Enter on a
file.

**Trace.** The latest `code_mode` program: title and state, its capability
calls in order as a tree (`├ └`, from omp), and a collapsed budget line. No
timing bars, as the web ruling says; per-call timing is a later protocol
change. Enter on the program opens the existing full program view.

**Session.** Rows: goal, jobs, queue, schedules, viewers, model, context,
cost, and a line saying the layout is remembered for this workspace. Enter on
a row opens the overlay that already shows it (`/goal`, `/queue`,
`/summary`, `/context`). The overlays stay; the tab is their index.

## 5. Strand focus from the timeline

The web timeline has a dot per row. The terminal version is two things.

1. **Inline strand tree.** When a strand spawns others, the spawn row becomes
   a small tree, one line per strand with its glyph, name, goal, state,
   context and elapsed time (taken from omp's task tree). The approval state
   sits on the line of the strand that caused it. The lines update in place
   as the strands move. These are the rows a person looks at to see which
   strand crossed into `main`.
2. **Hint mode.** Ctrl+T numbers every strand tag and tree line on screen and
   every card in the panel: `0` is `main`, then the roster order the panel
   uses. Pressing a digit focuses that strand and leaves hint mode; Esc
   cancels. `0` is also the way back ("All strands"), because Esc in the
   composer already interrupts work and must keep doing so.

![Hint mode](A-sonnet-standard-hints-dark.png)

A focus is the existing `submit.switch_active_strand`
(`packages/tui/src/tui/submit.gleam:533`): the transcript, the composer's
recipient and the panel's detail follow it together. The heading row
becomes a breadcrumb, `ws · main ▸ sub:tests`, where it reads
`transcript / main` today (`render.transcript_title`):

![Focused strand, wide](A-sonnet-wide-strand-dark.png)

A focus cancels nothing the operator typed: a draft stays in the editor,
addressed to the new strand, as the strip's Enter already does.

## 6. Layout memory per workspace

Remembered: left column open, right panel open, panel width class, and the
active tab. Not remembered: the focused strand, the session, and any
overlay. The owner's web rulings apply: a launch shows `main`.

Where: one small file under the launcher's state root, `<state-dir>/tui/layout.json`,
mapping the workspace root (`workspace.Context.path`,
`packages/tui/src/tui/workspace.gleam:16`) to `{left, right, tab}`. The
terminal already keeps files there for remotes (`claim.gleam`), so the
location is not new. It is read once at launch beside `workspace.discover`,
through the bounded read `workspace_file.read_small_regular`, with a total
decoder that returns the defaults for a missing, oversized or malformed file.
A change becomes a `SaveLayout` effect, so the step stays pure; the file is
written with mode 0600 and holds no conversation data. It needs no new FFI:
`simplifile` is already a dependency. Nothing crosses the wire, so it needs
no protocol change.

The defaults when nothing is stored are the widths above: both columns at 200
and up, nothing open below.

## 7. Key bindings and collisions

Bound today, read from `packages/tui/src/tui/interaction.gleam` and the
surface docs: Ctrl+C quit (line 496); Ctrl+G details; Ctrl+O and F2 open
agents (1125); Alt+Q queue (1120); Ctrl+D moves diff focus when a diff is
shown (1126); Tab steers or prompts, Shift+Tab toggles the rail (1338 and
1339); Esc interrupts (1337), or closes the surface on top; Left from an empty
composer opens the session picker (1376); Down from an idle composer enters
the strip (1236); **every other Alt+character interrupts and inserts** (1419);
Home, End, PgUp, PgDn, Up and Down edit or scroll. Inside the agent inspector
the digits 1 to 4 pick a tab and `[` and `]` page (714 to 725). Ctrl+S and
Ctrl+R act in the queue editor only.

| Key | Proposed action | Collision check |
|---|---|---|
| F2, Ctrl+O | Open the panel on Strands (today: the `/agents` overlay). Pressed again with the panel focused, close it | Same keys, same meaning; below 117 columns it is a sheet instead of an overlay |
| F3, F4, F5 | Panel on Changes, Trace, Session; toggle when already there | Unbound today |
| F1 | Show or hide the sessions column (146 columns and up) | Unbound; help is `/help` |
| Shift+Tab | Show or hide the panel | Replaces "toggle the rail", which the panel subsumes |
| Right, from an empty composer with no attachment | Focus the panel | Right only moves the cursor, which means nothing in an empty editor; the same argument the Left binding already makes |
| Left, from an empty composer | Focus the sessions column when docked, else open the picker as today | Unchanged where the column is absent |
| Ctrl+T, then a digit | Hint mode (section 5) | Ctrl+T is unbound |
| In the panel: Up, Down, Enter, `x` | Select, focus or open, stop | The strip's existing set |
| In the panel: `[`, `]`, `1` to `4`, Tab | Previous or next tab, jump, cycle the Strands filter | The inspector's existing digit and bracket convention; only while the panel has focus, so the composer keeps its characters |
| Esc in the panel | Return focus to the composer (the panel stays open) | Panel focus only; Esc in the composer is unchanged |
| Ctrl+D | Unchanged: composer or file navigator when Changes is showing | Unchanged |

Ctrl+B is avoided on purpose: it is the tmux prefix and Herdr runs terminals
in panes. Function keys need Fn on many laptops, so every key has a slash
command: `/panel strands|changes|trace|session`, `/panel hide` and
`/sessions`. Whether Herdr and common terminals pass F1 to F5 through must be
checked before the keys are fixed (open question 3).

## 8. Data each region needs

| Region | Source | In `session_view` today | New wire fields |
|---|---|---|---|
| Strand cards, status line, needs-input count | `agent_roster.Line` (`packages/session_view/src/session_view/agent_roster.gleam:84`), `strand_card.status_line` (`packages/session_view/src/session_view/strand_card.gleam:38`), `strand_card.needing` (69) | Yes | No |
| Strand detail: model, context, running, recent tools | roster line, `strand_card.context_words` (83), `agent_view` | Yes | No |
| Cache outlook | `cache_watch.outlook` (`packages/session_view/src/session_view/cache_watch.gleam:120`) | Yes | No |
| Strand filter counts | counts over `agent_view.Status` (`packages/session_view/src/session_view/agent_view.gleam:38`) | Yes | No |
| Inline strand tree | the spawn, result and nudge rows the line builders emit (`transcript_lines`) | Rows yes; updating them in place needs a fold of the roster into the spawn row, which the web lane does | No |
| Changes | `changes_view.fold` (`packages/session_view/src/session_view/changes_view.gleam:173`), `totals` (148), `label` (137); worktree observation (`worktree_view`) | Yes | No |
| Trace | latest `code_mode` program, `transcript_lines.code_mode_program` (`packages/session_view/src/session_view/transcript_lines.gleam:2371`) | Program and result yes; the calls listed in order need a new portable fold (`trace_view`) that the web pass also needs | No, for the list; timing needs `protocol-change/NNN.md` |
| Session tab: jobs, viewers | `session_summary.jobs` (`packages/session_view/src/session_view/session_summary.gleam:99`), `viewers` (122), `live_jobs.lines` (`packages/session_view/src/session_view/live_jobs.gleam:107`) | Yes | No |
| Session tab: context, cost | `context_view.footer` (`packages/session_view/src/session_view/context_view.gleam:358`), `Shared.usage` through `transcript_lines.money` (3058) | Yes | No |
| Session tab: goal, queue, schedules | `goal_view`, the cut's pending inputs, the schedule events | Yes | No |
| Sessions column | `session_selector` catalogue page and the picker's activity answer | Terminal-side, from the control connection; absent on a launch with no control | No |
| Collapsed repeats | a counted line over consecutive identical tool rows | New, in the line builders (`transcript_lines`) | No |
| Harness notices | the `[loom] background job ... was lost` text is today a prompt the daemon injects as a user turn | The fix is a speaker for harness text | **Unverified.** If the daemon sends it as a user entry with no origin marker, the client cannot tell it from a prompt, and a marker is a wire change needing a `protocol-change`. Check first |
| Layout | local file | n/a | No |

Nothing in the first four slices needs a wire change. The two items that may
are harness notices (an origin marker) and Trace timing.

## 9. What we took from omp

Taken:

- **Status next to the activity.** The line above the input reads
  `◒ streaming (3s) · esc to interrupt`, naming the cancel key as omp does.
- **Sub-agents as an inline tree.** Section 5. It replaces separate "forked"
  and "finished" rows, and gives hint mode something to number.
- **Tree glyphs and dimmed metadata** in the Trace tab's call list.
- **Collapse by default, one key to expand.** Already true (`Ctrl+G`); the
  Trace and Changes tabs follow it.
- **Reasoning dim, answer bright, diagnostics attached to the causing row.**
  Already the terminal's style; the approval state sits on the strand's own
  line.

Rejected, with reasons:

- **One column with no panes at all.** Replaced by the position at the top:
  one column by default, columns when the window has room.
- **Tinted tool blocks.** The terminal already uses a tint for the owner's
  turns and for assistant blocks (`theme.user_background`,
  `assistant_background`). A third tint for tool calls would blur that.
  Tool rows stay marker lines.
- **Titled rules around results.** They cost two rows per result and the
  compact rows users rely on would double in height at 24 rows.
- **The status line as the input frame, with no footer.** It needs a
  powerline font for its separators, which breaks character-cell honesty,
  and it removes the footer's capped sections that `footer_fit_test` pins.
  Open question 5 asks whether to fold the footer into the composer rule at
  wide widths only.
- **Inline images in the panel.** Images stay in the transcript, where they
  are today. A graphics-protocol image inside a column that can be resized
  or hidden would need per-cell cleanup the renderer does not have.

## 10. What we took from the owner's drives

The recordings show today's Loom in daily use. Each pain point is fixed in a
frame above.

| Observation | Frame | Change |
|---|---|---|
| About fifteen identical `✓ agent_wait · 2 subagents` rows | [standard-multi](A-sonnet-standard-multi-dark.png) and [narrow-multi](A-sonnet-narrow-multi-dark.png) | One counted, updating line: `✓ agent_wait · 2 subagents ×15 · last 51s ago` |
| A `[loom] background job ... was lost` notice drawn as a `› User` turn | same | A `◇ harness` notice in the signal colour, marked "a notice from Loom, not a message from you". Needs the data check in section 8 |
| A wall of identical 429 errors | same | `! provider 429 rate limited ×7 · retry in 8s` |
| The roster, queue strip and attention count work | same | Kept: the strip stays whenever the panel is closed, and `queue · 1 pending · Alt+q` moves to the heading row's right end |
| Claude Code's list under the input with a selected row | [narrow-multi](A-sonnet-narrow-multi-dark.png) | The strip is the same idea and stays; it shows the top four and `+2 more · F2 opens the list` |
| Codex's "Needs you 1" filter tabs | [standard-multi](A-sonnet-standard-multi-dark.png) | The Strands header counts: `All 6 · Needs you 1 · Working 4 · Done 1`; `n` jumps to the next one that needs you |
| pi's pinned TODO | every main frame | The one-line `▸ Todo · 3 of 5 done` stays above the composer, expanded by the existing key |
| Full-width approval blocks with numbered choices | not redrawn | The approval dialog (`approval_panel`) is already modal and selects no choice by default; it is out of scope and stays |
| A scrollback indicator with a jump to latest | [narrow-multi](A-sonnet-narrow-multi-dark.png) | The existing `↓ Scrollback · End for latest` heading, kept |
| Slash overlays anchored above the prompt | not redrawn | Already the palette's behaviour; unchanged |

Six agents at 80 by 24: the strip has room for four rows plus the overflow
line, so the sixth agent and the attention one are found through the footer
count (`1 needs you`) and `n`.

## 11. Terminal option (d)

Whether the terminal moves onto the shared `session_view` step
(`step.update` with a pure callback) is decided elsewhere. The measurement
and its outcome will land in `docs/review/terminal-option-d-2026-09-30.md`.
This note does not depend on it: every data source in section 8 is a
`session_view` module the terminal already imports.

## 12. Slicing into pull requests

Each slice builds and passes `make check` alone, and each that changes what
is drawn carries a virtual-terminal test at 200, 120 and 80 columns.

1. **Layout record and file.** `layout.json`, its total decoder, the
   `SaveLayout` effect. No visible change.
2. **Collapsed repeats and the harness speaker.** The line-builder fold and,
   if the data check allows, the notice. Fixes the owner's worst pain point
   on its own.
3. **The panel as a docked column.** Geometry in `layout.body_layout`, the
   tab bar, the Strands tab over the existing roster, F2 to F5, Shift+Tab,
   `/panel`. The rail and the 72-cell diff pane go away here.
4. **Changes and Session tabs** over `changes_view` and `session_summary`.
5. **The sessions column** at 146 columns and up, and F1.
6. **The inline strand tree and hint mode.**
7. **Trace** with its new fold.
8. **The 80 by 24 sheet.**
9. **Persist the layout:** wire slice 1 to slices 3 to 5.

## 13. Open questions for the owner

1. **Default at 200 columns and up: both columns open?** Recommended yes, as
   A2. Below that, nothing open.
2. **Is Right-from-empty-composer acceptable as "focus the panel"?**
   Recommended yes; it mirrors Left.
3. **F1 to F5 as panel keys, given Herdr and laptop Fn keys?** Recommended
   yes with the `/panel` commands as the guaranteed path, after a check that
   Herdr passes them through.
4. **Ctrl+T hint mode: a new pattern.** Recommended yes. The alternative is a
   transcript cursor, which the terminal does not have and which would need
   its own scroll and selection rules.
5. **Fold the footer into the composer rule at wide widths, as omp does?**
   Recommended no for now; revisit after slice 3.
6. **Layout file under `<state-dir>/tui/`, keyed by the workspace path?**
   Recommended yes; the alternative is a per-repository dotfile, which
   writes into the user's checkout.
7. **Three strand hues, or two more added to the theme?** Recommended three;
   the name is always shown.
8. **Is the harness-notice fix in scope if it needs a wire marker?**
   Recommended: do the client half (collapse repeats) now and file the
   marker separately.
9. **Sessions column on a launch with no daemon control** (demo, some remote
   attaches): hide it. Recommended yes.
