# The web UI redesign: three columns, a tabbed panel and a timeline

**Status: proposed, for the owner's review.** This note turns the mockup the
owner approved on 2026-09-29 (A2) into a plan that can be built in small
pull requests. It is the visual and structural companion to
[the web UI note](web-ui.md), which records what the page shows and why, and
where the two differ on layout, the right pane or colour, this note governs
(the list is in section 9). It changes no rule of
[protocol-change/051](../../protocol-change/051-web-view-route.md). Where a
piece of the design needs a rule 051 does not have, the note says which
addendum is needed and what it must decide, and does not decide it.

It was written against `main` at `3002334984ab` with two open pull requests
assumed to land first:

- [#635](https://github.com/Roasbeef/loom/pull/635) folds the memory context
  the daemon attaches to each prompt and allows up to four pages per
  principal and session.
- [#636](https://github.com/Roasbeef/loom/pull/636) makes each strand chip a
  focus button and adds a read-only session list beside the page, drawn for
  operator pages only.

Operator-only session switching is ruled by the owner (2026-09-29) and
planned as a follow-up to #636, with its own 051 addendum. It is built
(step 11 of section 8): the addendum "switching sessions" in 051 records the
rule, and section 3.4 says what the redesign needs from it.

The mockup is [`web-design/A2-refined.html`](web-design/A2-refined.html). It
is a static page with a small script, and it is the source of truth for
layout and behaviour. Where this note and the mockup differ, the note says so
in section 9 and gives the reason.

## 1. What was chosen and why

Three concepts were made from one brief, one each by Sonnet 5.5, Opus 5.5 and
Fable 5.1:

| Concept | Idea | Light screenshot |
|---|---|---|
| A | A strand rail beside a calm transcript | [A-sonnet-light.png](web-design/A-sonnet-light.png) |
| B | A strand roster with a decision dock, in three columns | [B-opus-light.png](web-design/B-opus-light.png) |
| C | A "Now" board with a dock | [C-fable-light.png](web-design/C-fable-light.png) |

The owner picked A. B and C showed too much at once. The team's feedback was
that A is minimal, quieter and easier to approach; that B carries useful
information but is noisy, while its structure is better (it reads left to
right, its panels collapse, and it exposes detail progressively); and that
C's centre view is interesting but the weakest overall.

The direction for the refinement was to keep A's calm, with a transcript that
scrolls and keeps the focus while the two sidebars do the context switching;
to let most content be hidden or collapsed, with the collapse state
persisting per workspace; to give the right side tabs, one for each kind of
extra content, as the Claude, Codex and t3code apps do; and to let a sidebar
stay fixed, be hidden, or show more detail about one strand.

A2 is that refinement: A's typography, palette and tone, in B's three
columns, with B's density left out (a strand card shows a name and one status
line where B shows five facts). Screenshots:

| View | Light | Dark |
|---|---|---|
| Default | [A2-refined-light.png](web-design/A2-refined-light.png) | [A2-refined-dark.png](web-design/A2-refined-dark.png) |
| Both sidebars hidden | [A2-refined-focus.png](web-design/A2-refined-focus.png) | |
| One strand focused | [A2-refined-strand.png](web-design/A2-refined-strand.png) | |
| Another session viewed | [A2-refined-session.png](web-design/A2-refined-session.png) | |

## 2. The layout

The page stays one viewport tall and never scrolls as a whole, as the
"frame is pinned" addendum to 051 already requires. Its parts are a top bar
across the full width, and below it three columns.

| Region | Width | Holds |
|---|---|---|
| Top bar | full, 44 px | toggles, name, status, context, cost |
| Left sidebar | 232 px | workspaces and sessions |
| Centre | the rest, transcript at most 780 px wide | the transcript and the dock |
| Right panel | 340 px | four tabs |

Each region below says what it shows, what is collapsed by default, and what
expands on a click.

### 2.1 The top bar

It shows, from left to right: the left-sidebar toggle with its shortcut
hint (`⌘B`); the brand; the session's location as `workspace path / session
name`; the connection status; and, at the right end, the context estimate,
the estimated cost, and the right-panel toggle with its hint (`⌘⌥B`). The
mockup also has a Theme button (see section 6.5).

The location line, the status and the ended-page notice are today's heading
(`web_view/view/heading`) moved into the bar. The notice for a page with no
session stays a child of that heading, as the "a page with no session says
why" addendum requires, so that no region after it changes its path.

The context figure is the engine's own estimate for the strand on screen
(`session_view/context_view.footer`, which reads `ctx ~41%`). The tilde stays:
the figure is an estimate and the mockup's `ctx 41%` would overstate it. The
cost is the figure the terminal's footer shows as `est $`. It is the
session's running total across strands: `event_fold.receive_usage` folds every
`UsageChanged` event, for any strand, into `shared.usage`, seeded by the full
snapshot's usage, and a usage report carries no strand. The bar labels it
"session".

Nothing in the bar expands. The two toggles are the only controls.

### 2.2 The left sidebar

It shows workspaces as group headings with a session count, and under each
heading the sessions in it, newest first, with the current workspace's group
first and the session on screen marked.
This is the read-only list of #636, with the mockup's styling. A row shows the
session's name, and, for the session on screen only, one thin bar per live
strand in the strand's hue, pulsing while the strand works.

Each workspace's heading is drawn as a small, muted, uppercase,
letter-spaced label (an eyebrow) above its group, and a one-pixel hairline in
the `divider` token, with space above and below it, separates one group from
the next, so that it is clear where one group ends and the next begins; a
group has no box or background of its own (team feedback, 2026-09-29).

Collapsed by default: nothing in it is collapsed. The whole sidebar can be
hidden (section 4).

On a click:

- A bar of the session on screen focuses that strand (section 3.1).
- A row of another session switches to it, for operator pages only
  (section 3.4). On an observer's page the sidebar is not drawn, which is
  #636's ruling.

Three things in the mockup's sidebar cannot be drawn from data a page has,
and are left out of the first build (details in section 9): the `New
session`, `Goals` and `Jobs` buttons, which need pages of their own; the
strand bars and the badge on rows of sessions other than the one on screen,
which need an activity read a page does not make (owner, 2026-09-29, issue
#569: bars show only for the session being viewed, other rows keep name and
resident or saved state, and no new data is added); and the `Scheduled`
section, which lists schedules across sessions where a page knows only its own
session's.

### 2.3 The centre: transcript and dock

The transcript is the pinned frame's scroll container, `<loom-follow>`, as
today. It is a single vertical timeline: a thin line down the left edge with
one dot per row in the hue of the strand that row belongs to. Rows are the
ones the lane already draws (`web_view/view/lane`), in the collapsed
vocabulary the mockup shows:

| Row | Collapsed to | Expands to |
|---|---|---|
| The owner's prompt | the text, in a bordered bubble | nothing |
| Memory context | `Memory · n notes` | the digest, cut to the page's existing bound (#635) |
| Reads and edits | `Read 3 files, edited calc.gleam +6 -0` | the call list |
| Reasoning | `Reasoning · 9s` | the reasoning text |
| A `code_mode` call | `code_mode · file · running 1.2s` | the program and its result |
| A sub-strand's brief | one line with its state | the strand's output, by focusing it |
| A peer's question | one line | the question |
| An advisor nudge | a bordered card, text only | nothing |
| A cache miss | the dashed line the page draws today | nothing |

The grouping of a turn's work into one divider is the rule `turns` already
applies (`▸ worked 48s · 4 steps · 2 files`); the mockup's rows illustrate
the collapsed style and do not change the grouping. Expansion uses the
existing `<loom-fold>` and `<loom-expand>` elements, not native `<details>`,
so that a fold's state stays in the browser and a server patch leaves it
alone.

The centre shows the strand in focus. With no strand focused (the default,
`main`), it shows `main`'s transcript including the rows where another strand
crossed into it: a spawn row, a result card, a nudge, a peer message. This is
what the page draws today, restyled. It is not an interleaving of every
strand's internal work, which would need a new projection over several
strands' windows, and it is not built.

Focusing a strand shows a breadcrumb above the transcript (`session ▸
strand`, an `All strands` link, and the `Esc` hint) and the strand's own
transcript below it.

The **dock** is the footer of the centre column and holds, from top to bottom:

1. The approval cards, when any are pending. They stay in the dock, directly
   above the composer, with the 600 ms arming delay and the 35% height cap. The
   mockup draws a "Needs you" card with Approve and Deny in the Strands tab;
   that placement is not taken (section 6.1).
2. The todo line: `Todo · 3 of 5 done · check it`, one line, collapsed by
   default. It expands (a `<loom-fold>`) to the phase that holds the active
   task, which is today's todo panel, with its height cap. The panel is not
   drawn when the strand has no board, and it is drawn for the focused strand
   only.
3. The composer: `To <strand tag>`, the editor, and the action row. The
   target tag names the strand in focus, and the row shows `Send`, or `Queue`
   and `Steer` while the strand is busy. Slash completion and Cmd or Ctrl with
   Enter are unchanged (`<loom-composer>`).

The mockup's `Alex is typing` line is not built: typing is not in the
protocol (`web-ui.md`, section 4).

### 2.4 The right panel

Four tabs: Strands, Changes, Trace and Session. The Strands tab carries a
badge counting strands that need input (an `agent_view.Status` of
`NeedsInput`). One tab is active at a time; the state is in the browser.

**Strands.** The list view shows a header (`Strands · n`, `cache hit`) and
one card per strand: a ring, the name, and one status line (`Working ·
code_mode`, `1 nudge pending`, `Needs approval`, `Finished 1m 12s`, `Asked 1
question`). The focused strand's card has an inset bar in its hue. Model,
context, cache expiry and cost are not on the card. A strand that needs input
shows its status line in the attention colour and nothing else; a click
focuses it, which draws its approval card in the dock.

The ring is the cache ring the page draws today. The mockup fills it with a
hit-rate percentage. The owner ruled (2026-09-29, issue #569) that the ring
keeps the cache outlook, the time before the cache expires, and shows no hit
rate. `cache_watch` computes none.

Clicking a card, or any other strand control, focuses the strand and shows the
**detail view** in the same tab: a `← Strands` link, a larger ring with the
name and status, the four figures (`Model`, `Context`, `Cache expires`,
`Cost`), and a `Recent` list of the strand's last few events with their ages.
`← Strands` and `Esc` return to the list.

**Changes.** A header (`Changes · n files`, `+14 -2`), then one row per file
with its counts. The first file's diff is open and the others are collapsed.
Where the data comes from is section 6.3.

**Trace.** For the most recent `code_mode` program: a title with its state, the
program's capability calls listed in order from what the page already
receives, and a collapsed `Budget` line (the budget the call named and the
vetting state). It has no timing bars (owner, 2026-09-29, issue #569).
Section 6.3 says why.

**Session.** A key and value list: goal, jobs, schedules, viewers, estimated
cost; and a collapsed `Cost by strand`. It ends with a note that the layout is
remembered for this workspace. Its data needs are in section 6.4.

## 3. Navigation

### 3.1 Focusing a strand

Five places focus a strand, and they behave the same way:

- a dot on the timeline;
- a strand tag in a row (`main`, `sub:tests`, `advisor`);
- a strand card in the panel;
- a strip bar in the sidebar, for the session on screen;
- the `Review in panel` and `Open trace` style links in the transcript, which
  are the same control with a different target (a strand, or a tab).

The result is the same for each. The centre shows that strand's transcript
with the breadcrumb, the panel opens on the Strands tab in the detail view
(opening the panel if it was hidden, as the mockup does), and the composer's
target becomes that strand. The state that says which strand is in focus is
the shared record's `active_strand`, which `step.focus` in #636 moves. The
browser holds no copy of it. The strand's context, notes and nudge reads
follow it as #636 already arranges.

Two consequences of #636 that the design relies on:

- A focus cancels the lane's unsent frames. A draft stays in the composer,
  addressed to the new strand. This is the reason the target tag must always
  name the strand on screen.
- Approval cards are drawn for the strand on screen only. Focusing `main`
  hides the card of `sub:tests`. The card's strand shows `Needs approval` in
  its status line, so the person can see there is one and is one click from
  it.

**Which controls carry a handler.** Every handler in the tree is callable by
whoever holds the socket, and an observer's socket admits the strand clicks
of #636 at one path prefix. If each dot, tag and link carried its own
handler, a page with 300 rows would carry 300 more admitted paths, and the
observer filter would have to admit a click under the lane. Instead only the
strand cards carry a handler (they are #636's chips, moved). Every other
strand control is a marker with no handler: a fixed `data-loom-focus`
attribute whose value is the strand's position among the listed strands
(`0` for `main`, then the other listed strands, the advisor after them and
the settled group's cards last), never a name.
A client element hears a click on a marked element and clicks the card with
the same position, which is an ordinary click on an ordinary handler. This
keeps the admitted surface at what #636 decided. It is the same shape as
`<loom-follow>` hearing the `data-loom-older` marker, and it needs a 051
addendum for one new thing, a client script that clicks a server-drawn
control (section 6.1). The alternative, a handler per control and an observer
filter that admits a click beneath the lane, is larger and is not
recommended.

A dot is not a tab stop. It is a decorative span with the marker, hidden from
assistive technology, and the same action is reachable from the strand cards
and the tags, which are real buttons. The mockup gives every dot a button
with a label; on a page with hundreds of rows that is hundreds of tab stops.

**Settled strands.** #636 lists only strands the strip lists and says a
settled strand "cannot be focused from the page". A2 lists finished strands
as cards and lets them be focused (`sub:docs`, `Finished 1m 12s`). The
redesign would therefore need the strand list to include settled strands, up
to a bound (the design suggests the newest six, with `+n earlier` as text),
each with its own card handler. `agent_roster` keeps only a count of settled
strands, so this is a retention change in `session_view` that the terminal's
strip also feels, as well as a change to #636's admitted-path rule. The owner
ruled (2026-09-29, issue #569) that it is a later pull request of its own,
after this redesign, and not part of step 5.

That pull request landed as a collapsed group below the live cards, the first
six in reverse row order (rows carry no join time) with `+n earlier` as text. `agent_roster.chips` already saw every
strand, so it needed no retention change; it now returns the settled lines
instead of their count. A settled card names how the strand ended and shows
no duration or time, since a finished operation's clock keeps running and no
capture records when it ended; the group's open state is the browser's and is
not stored (protocol-change/051, the addendum on settled strands).

### 3.2 The breadcrumb, `Esc` and the way back

The breadcrumb reads `<session name> ▸ <strand>`, with `All strands` and the
`Esc` hint at the right. `All strands`, `← Strands` and `Esc` all focus
`main`. The first two are marker controls that click `main`'s card. `Esc` is a
key and is covered in section 6.2.

The mockup distinguishes "no strand focused" from "`main` focused": clicking
`main`'s card shows a detail view for `main` over the same merged transcript.
Loom has one state, the active strand, and `main` is the default. The design
follows the engine: focusing `main` is `All strands`, shows the list, and
shows no breadcrumb. `main`'s model, context and cost are still reachable, in
the top bar and the Session tab, but its detail view is not drawn. (Default
adopted by the orchestrator, open to the owner's override: a detail view for
`main` would need a second piece of state on the server, which strand's detail
is open.)

### 3.3 The composer target

The tag in the composer names the active strand, so it follows every focus.
The `▾` in the mockup suggests a menu for changing the target without
changing focus. That is not built. `web-ui.md` (section 3.7) says browsing
must never retarget a draft, and #636 chose the opposite: the composer always
addresses the strand on screen. This note follows #636, and a target menu is
left to a later change that would also have to reconcile the two.

### 3.4 Switching sessions

Only operator pages switch (the owner's ruling of 2026-09-29). An observer
page has no sidebar and cannot switch.

Switching is navigation. Each page is bound to one session by its key, its
cookie and its nonce, and its component runs one session's lane. To open
another session the page asks the daemon for a ticket, and the browser
navigates to `/ui/sessions/<id>?ticket=<ticket>`, which exchanges it and lands
on that session's page. Step 11 built the mechanism, and the 051 addendum on
switching sessions records it: the page draws a hidden `<loom-switch>` whose
`to` attribute carries the ticket's address once the daemon has minted one,
and the element checks the address's shape before it navigates. A row is a
button only for a running session other than the one on screen. The redesign
needed three things from it:

- **Several pages per principal** (#635). A switch adds a page and does not
  end the page left behind. The cap of four is per principal and per session,
  so a switch to session B never displaces the page left on session A.
- **The ceiling.** A ticket minted from a page carries a ceiling no higher
  than the page's own.
- **A route back.** The sidebar row of the session the person came from is
  how they return, so the sidebar is drawn on the new page as well.

**Every session-scoped region follows a switch.** The mockup swapped the
path, context, cost, breadcrumb, strand list and composer target when the
person opened another session, and hid the todo and the badge. Its Changes,
Trace and Session tabs kept showing the old session's content. That must not
happen here, and the design makes it a
property of the construction and a tested invariant, not a list of things a
script remembers to update. Because a switch is a navigation, the new page
runs a new component over a new lane, and every region below is drawn from
that component's model alone. No region reads anything from the page that was
left. The invariant is that no region takes an input that is not derived from
the page's own session record, and the test is that a page for session B
drawn after a page for session A holds no text from A.

| Region | Follows a switch because |
|---|---|
| Top bar: location, status, context, cost | drawn from the new component's catalogue label, connection and usage |
| Sidebar | the same list, with the new session marked and its strand bars drawn |
| Transcript, breadcrumb, timeline | the new lane's rows |
| Strands tab, list and detail | the new session's strands |
| Changes tab | the new session's edits (section 6.3) |
| Trace tab | the new session's latest program |
| Session tab | the new session's goal, jobs, schedules, viewers and cost |
| Todo line | the new session's board |
| Approval cards and needs-you counts | the new session's pending escalations |
| Composer target and draft | the new session's `main`; the draft is a browser value in the old page and does not cross |

Three things persist across a switch and are not session-scoped: the two
sidebars' open state, the active tab, and the theme (section 4). The focused
strand is session-scoped and is not stored: a new page shows `main`.

A switch that instead re-attached the lane inside the same component was
considered and is not proposed. It would make each of the regions above a
reset that a change could forget, and it would put a second session's
authority inside a page whose 051 grant names one.

## 4. Collapse, hide and persistence

**Both sidebars hide.** The left toggle sits at the left end of the top bar and
the right at the right end. `⌘B` (Ctrl on other systems) toggles the left one
and `⌘⌥B` (Ctrl+Alt) the right. A hidden sidebar's column takes no width, its
content is not focusable, and the centre widens to fill the page, as in the
"both hidden" screenshot. The width change takes 180 ms and is removed under
`prefers-reduced-motion`. A hidden region's content is still drawn by the
server and still patched, since the server does not know the region is hidden;
the bound on Changes and Trace content (section 6.3) is what keeps that cost
small.

**Narrow windows.** The mockup hides the right panel below 900 px and keeps
the sidebar; #636 drops the sidebar below 1180 px. The design hides each
sidebar below a breakpoint at which its column would leave the transcript under
640 px, and has no overlay in the first build. (Default adopted by the
orchestrator, open to the owner's override.)

**What persists, and where the state lives.** Owner, 2026-09-29, issue #569:
layout state lives in the browser's `localStorage`, per workspace.

| State | Scope | Lives in |
|---|---|---|
| Left sidebar open, right panel open | per workspace | the browser's `localStorage` |
| Active tab | per workspace | the browser's `localStorage` |
| Focused strand | not persisted | a reload shows `main` (owner, 2026-09-29, issue #569) |
| Session viewed | not persisted | the page's address |
| Theme | per browser | the browser, if the toggle is built |

The mockup keys one record by workspace and stores the focused strand and the
viewed session in it. Neither carries over.

- **The viewed session is not stored.** A page's address names its session,
  and `loom ui --session <id>` opens that one. Restoring another session on
  load would override the link the person just opened and would need a ticket
  minted at load, and tickets are single use.
- **The focused strand is not restored across a reload** (owner, 2026-09-29,
  issue #569). Restoring it would need the browser to name a strand to the
  server, which #636 avoided ("a browser's click chooses among the chips that
  exist and cannot name a strand"), so the change needs no event, query
  parameter or addendum.

**Storage.** The owner chose the browser's `localStorage`, written by a client
element, over a per-principal server record (Option B below, not built). The
state is presentation only and nothing the server needs, which is the
condition `docs/lustre.md` sets for state that lives in a client component.
It needs no new socket event and works identically for observer and operator
pages. 051 mentions browser storage once, for the page nonce in
`sessionStorage`, and states no rule for other storage. `localStorage` is
scoped to scheme, host and port, so a page on another loopback port cannot
read it, which is the property the nonce relies on. The content security
policy does not restrict it. The costs:

- It is lost when the daemon's address changes. `loomd` binds `127.0.0.1:0`
  by default and prints the port, so a restart on a new port is a new origin
  with empty storage. A fixed `--bind` avoids this.
- `127.0.0.1` and `localhost` are different origins, and each has its own
  layout.
- It does not follow the person to another browser or machine.
- Tabs of one workspace share it and do not see each other's changes until
  they reload.
- The key needs a workspace identity. The client-component rule says an
  element's attributes hold daemon identities or numbers, and a path is
  neither. The design passes a digest of the canonical workspace path, made
  by the daemon and handed to the component in `component.Start`, so the
  attribute is an identity. (Reading the catalogue's workspace path directly
  is the alternative; the heading already draws it as a `title`, on the
  grounds that the owner and host write it, not the agent.)
- Storage is reached only through two new single-call exports in
  `internal/dom.mjs`, one that reads an item and one that writes an item, each
  wrapping its storage access in try/catch and returning a result, because
  storage can throw in a private window. They are bound in Gleam beside the
  existing DOM bindings. Everything else is Gleam in `layout_rule`: the
  per-workspace key, the encoding, the total decoding of the saved layout, and
  the defaults when nothing is stored or it fails to decode. The tests for
  `layout_rule` run on Node 18 and import neither Lustre nor the DOM binding.
  `scripts/web_client_js_check.sh` should keep refusing any other storage use
  outside `dom.mjs`.

*Option B, server-side, per principal and workspace (not chosen).* A record in the
daemon's state directory, read when a page opens and written when the person
changes the layout. It survives restarts and follows the principal across
browsers. Its costs are larger: a new persistence surface in the daemon; a
new socket event to write it, which an observer's page must also send, so the
observer filter admits a second kind of event from a page that today may send
clicks that only read; a decision on who may write whose layout; a decision
on how a change reaches the other pages of the principal; and a round trip
for what should be an instant toggle, so the browser would still apply it
first and the server would only remember it.

The sidebars and the tab are preferences that are cheap to reset, a daemon
restart is rare, and Option B's costs are all in the protocol. If restarts on
a new port prove to be a nuisance, the owner can fix the port or move to
Option B later without changing what the elements do. The storage still needs
a 051 addendum (step 7), because 051 states no rule for it.

## 5. Theme tokens

The page's tokens are the `--color-*` names in `web_client.css` (`@theme` for
dark, a `prefers-color-scheme: light` block for light). A2 uses different
names. The table maps each A2 colour to the existing token and gives both
palettes as the mockup defines them. A change of value keeps the name, so no
class changes; a new token is added to `@theme`.

| A2 | Light | Dark | Token | Change |
|---|---|---|---|---|
| `bg` | `#f6f5f2` | `#141517` | `bg` | value |
| `panel` | `#ffffff` | `#1b1c1f` | `bg-raised` | value |
| `sunk` | `#efede8` | `#111214` | `bg-sunk` | new, for the left sidebar |
| `line` | `#e2dfd8` | `#2b2d31` | `divider` | value |
| `ink` | `#1d1c1a` | `#e8e6e1` | `fg` | value |
| `mute` | `#6f6b63` | `#9a978f` | `fg-quiet` | value |
| `faint` | `#a29d92` | `#66645e` | `fg-faint` | new, non-text marks only |
| `main` | `#3b5bdb` | `#7c96ff` | `current` | value; it is also the focus ring and link colour |
| `adv` | `#d9822b` | `#f0a24f` | `advisor` | value; today violet |
| `warn` | `#d9822b` | `#f0a24f` | `signal` | value; now the same as `advisor` |
| `peer` | `#8b5cf6` | `#a78bfa` | `peer` | new; today's peer card is hatched grey |
| `tests` | `#0f9d8a` | `#3cc9b4` | `strand-2` | value |
| `docs` | `#7a8a3a` | `#a3b85a` | `strand-3` | value |
| `ok` | `#2f9e44` | `#51cf66` | `added` | value |
| `bad` | `#d6336c` | `#f06595` | `danger` | value |
| `code` | `#f1efe9` | `#212226` | `code` | new, code blocks and diffs |
| `addbg` | `#e6f4ea` | `#17301f` | `added-bg` | value |
| `delbg` | `#fbe9ef` | `#3a1a26` | `removed-bg` | value |

Tokens the mockup does not define:

- `bg-user` takes the value of `bg-raised`, and the user bubble gets a 1 px
  `divider` border, as in the mockup. `bg-agent` is used by no class in the
  views and is removed.
- `strand-4` to `strand-6` keep their values. The mockup shows two
  sub-strands and defines two hues, and a session can list five. The token
  pull request picks values for the remaining three from the same family and
  checks them against the rule below.
- `shadow-card`, from the mockup's shadow (light: `0 1px 2px rgba(0,0,0,.05),
  0 4px 14px rgba(0,0,0,.05)`; dark: `0 1px 2px rgba(0,0,0,.4)`), is new.
  `web-ui.md` says elevation is drawn with a border and not a shadow; the
  mockup uses both, and this note follows the mockup.

Four things about these palettes need a decision or a check in the token pull
request.

**Contrast in the light theme.** Several A2 light colours fail the 4.5 to 1
ratio for small text on their own backgrounds (measured against `bg`,
`bg-raised` and `bg-sunk`): `fg-faint` is 2.5, 2.7 and 2.3 to 1, `advisor` is
2.7, 2.9 and 2.5, `strand-2` is 3.1, 3.4 and 2.9, `added` is 3.2, 3.4 and
2.9, `strand-3` is 3.5, 3.8 and 3.3, `peer` is 3.9, 4.2 and 3.6, and `danger`
is 4.2, 4.6 and 4.0. In the dark theme every hue clears 6 to 1, and only
`fg-faint` (3.1, 2.9 and 3.2) fails. The mockup uses these colours as text in
strand tags, names, the `Esc` hint and mono labels. The design keeps A2's
values for marks (dots, rings, bars, borders) and uses a darker text value
wherever a hue is text on light. The existing light `signal` (`#9A5F0A`) is
the precedent. `fg-faint` is never used for text that carries meaning. The
pull request adds a check that computes the ratios for the token pairs the
stylesheet uses, so the rule is a gate and not a note.

**Theme switching.** The stylesheet follows `prefers-color-scheme` only, and
its light block sets the tokens on `:root, :host`, so each custom element's
shadow root gets its own copy of the values. A manual toggle that sets
`data-theme` on `<html>` would probably lose to those `:host` rules inside
every shadow root, since a rule on the host beats a value inherited from the
document. The toggle, if built, has to
set the attribute where the shadow roots can see it or write the tokens on
`:root` only and let them inherit. That needs a browser check, and the toggle
is section 6.5. (Built: the toggle sets `data-theme` on `<html>` and the stylesheet
sets every token to `inherit` in a `:host` rule so the shadow roots take the
root's values. A headless Chrome check confirmed both the failure without that
rule and the fix.)

**Advisor and warning share a value.** A2 uses one amber for the advisor and
for warnings. The state glyphs are always paired with words, so colour does
not carry state alone, but a nudge card and a `signal` element look alike.
The approval card must not look like any transcript element (051, "The
approval card"). The mockup draws it in `danger`, and no transcript row uses
that as a border, so the requirement holds; the pull request that draws the
card pins it with a test that no lane class uses the approval card's border
token.

**Typography.** The mockup uses `system-ui` at 14 px and a system monospace
at 12 px, which is what the stylesheet has. The page loads no fonts, and
nothing changes.

## 6. Security and protocol

The rules that decide what a page may do are in 051 and its addenda, and in
[the checklist](../lustre.md) for a change to `web_view`. This section goes
through each new behaviour and says what covers it.

### 6.1 What each behaviour needs

| Behaviour | Covered by | Needs |
|---|---|---|
| Restyle: tokens, rows, cards | CSS only | nothing |
| Three-column shell, top bar, sidebar and panel drawn by the server | "Nothing from the session becomes markup"; the sidebar rules of #636 (operator pages only) | nothing, but see paths below |
| Moved event paths | 051 names the paths by constant (`strip_path`, `older_path`), not by value; `page_events_test` and `ui_socket_test` pin the values | nothing, at most a one-line edit to #636's parenthetical that quotes `strip_path`'s value |
| Sidebar and panel toggles, tab choice | client-component rules in `lustre.md` ("Nothing the server needs"); real buttons | nothing, if the element holds no key handling |
| Strand focus from cards | #636's addendum, admitted for observers at one prefix | nothing, once the cards keep that prefix |
| Focus from dots, tags, breadcrumb and links | none | a 051 addendum: a client element that hears a click on a fixed marker and clicks a server-drawn strand card |
| `Esc`, `⌘B`, `⌘⌥B` | the approved keydown listener is passive and reads nothing | a 051 addendum, section 6.2 |
| Layout in `localStorage` | none (051 mentions only `sessionStorage` for the nonce) | a 051 addendum (step 7): storage is reached only through two single-call exports in `internal/dom.mjs`, and `scripts/web_client_js_check.sh` keeps refusing any other storage use outside that file |
| Session switching | proposed in #636's addendum | its own addendum, already planned |
| Changes from transcript edits | session text drawn as text nodes | nothing new |
| Trace | the calls the page already receives, listed in order | nothing; timing bars would need a later `protocol-change/NNN.md`, section 6.3 |
| Viewers list | the reasoning of #636's list ruling | operator pages only (a default the orchestrator adopted, open to the owner), section 6.4 |
| Theme toggle | none | storage and theme decisions, section 6.5 |

**The approval card does not move.** The owner ruled on 2026-09-27 that cards
stay directly above the composer, with the arming delay. The mockup's `Needs
you` block with Approve and Deny in the Strands tab would put a decision
control in a region outside the dock and outside the rules that region has
(the card is drawn from the escalation record alone, in a region transcript
content cannot occupy, Deny first, nothing focused, buttons outside any form).
The design keeps the card in the dock and lets the panel and the transcript
point to it: the strand's card says `Needs approval`, the transcript row says
`waits for approval` with no button and no `Review in panel` link, and
clicking the strand's card focuses it, which draws its card in the dock. The
panel carries no decision control.

**The observer's page.** An observer's page gets the same panel with the same
strand cards (focus is admitted for observers under #636) and no decision or
composer controls. It gets no sidebar. Every handler the redesign adds to the
observer's tree must be one the strand-focus addendum already admits, or its
own addendum widens the observer filter. The design adds none.

**The mockup's advisor buttons.** The nudge card in the mockup has `Deliver to
main` and `Dismiss`. The owner ruled (2026-09-29, recorded on issue #569)
that nudges are shown read-only, with no accept or dismiss, and are delivered by the primary's next
run. The buttons are not built.

**Paths.** The shell moves the heading into the top bar and the strand chips
from the strip to the panel, so `component.older_path` (`0\t2\t0\t0` today),
`component.strip_path` (in #636), the composer's form path and the pinned
order of the page's children all change. `ui_socket.observer_accepts`,
`page_events_test` and the route tests pin them. The shell pull request
updates each; no addendum is needed. The panel
should be drawn as the last child of the page, as #636 does with the sidebar,
so a later addition does not move an admitted path again.

### 6.2 Keyboard shortcuts

The addenda so far approve three key listeners and no more. `<loom-composer>`
listens for `input` and `keydown` on its own editor only. `<loom-follow>`
listens passively for `keydown` inside the transcript and reads nothing from
the event. Neither acts on a key outside the editor, and the rule behind them
is that no key may decide an approval and no client element takes focus near
one. The redesign needs three keys that act at the page level:

| Key | Effect |
|---|---|
| `⌘B` or `Ctrl+B` | toggle the left sidebar |
| `⌘⌥B` or `Ctrl+Alt+B` | toggle the right panel |
| `Esc` | focus `main` when another strand is focused |

The first two change client state only. `Esc` changes server state, because
the focused strand is the server's: the element does not send an event, it
clicks the marker control for `All strands` (section 3.1), which is the same
click a pointer makes.

The addendum for these keys must decide:

- **Scope.** A listener on `document` hears keys with focus anywhere. A
  listener on the shell element hears only keys with focus inside it, which is
  everything on the page but is a smaller claim. The design proposes the shell
  element, because the page has no content outside it. That choice has a
  consequence the addendum must argue: the shell's slot contains the dock, so
  a key listener on `<loom-shell>` is the first client element with an
  approval card in its subtree. `docs/lustre.md` says "No key handling and no
  focus near an approval card", and this is a departure from it.
- **The key set.** Exactly these three. The mockup matches `e.key` `b` for
  `⌘B` and `e.code` `KeyB` only for the Alt combination, since Alt changes
  `key` on macOS. The design matches `code` for the letter in both, and `key`
  for `Escape`. Any other key is not read.
- **Where they do not act.** Not while an input method is composing. Not when
  the event was already handled (`defaultPrevented`), which is how the
  composer's own `Esc` for closing its list wins. Not when the target is in
  the composer's editor for `Esc`, so that `Esc` in a draft never changes the
  focus. Not inside an approval card. Whether a shortcut acts when focus is in
  the editor at all (`⌘B` has no meaning in a textarea) is left to the
  addendum, with the proposal that it does.
- **Approvals.** A key that changes which strand is in focus changes which
  approval cards are drawn. It decides nothing, and the addendum states that
  as the rule: none of these keys sends a decision, and none takes focus.
- **Browser conflicts.** `Ctrl+B` opens the bookmarks sidebar in Firefox, and
  a page cannot override every reserved browser shortcut. The pull request
  checks the three keys in Firefox, Chrome and Safari and records which
  browsers honour them. A shortcut a browser keeps still works as a button.

Every control the keys reach is also a real button, so nothing is
keyboard-only.

### 6.3 Changes and Trace: data the page does not receive today

**Changes.** The terminal's `/diff` reads the worktree through
`request_visible_worktree`. The daemon serves worktree bytes to an Owner
binding only (`worktree_owner` in the gateway), a page is capped at Operator,
and the page never sends that read. So a page cannot show a git diff today,
and 051 records it as a bound (the operator-commands addendum), so a change
would be a ruling and not a view.

Owner, 2026-09-29, issue #569: Changes shows only diffs from the session's own
edit tool calls, and makes no worktree read. The page holds the records of the
session's edits (`fs_edit` calls and their results, the `tool-patch` lines it
already draws). A `session_view` module folds them into files with counts and
hunks, labelled "from this session's edits", the fallback `web-ui.md`
(section 3.6) already names. It shows what the agent wrote, not what is in the
tree, so it omits a change made outside the session and a change since
reverted. A git diff for a page would mean letting an Operator page read
worktree bytes, which are Owner-only, and is not planned.

The fold must bound what the page holds and draws: a file count, lines per hunk,
and a total, cut with a fixed line, as `view/expansion.capped` does for
expanded rows. The diffs are session text, so drawn as text nodes; a diff line's
class (added, removed, context) comes from a closed type the fold computes,
never from a string built from the text.

**Trace.** The mockup shows per-call bars for one program (`cap/fs.read`,
`cap/proc.run`, with durations) and a budget. The page has the program's
source and its result, drawn by `code_mode_program` in
`session_view/transcript_lines`. A search of `session_view` and
`tools/codemode` found no per-capability-call timing recorded in core events,
`session_view/tool_activity`, the code-mode result or `cap`, and the terminal
has no Calls tab. The bars would need the daemon to record and publish
per-call timing, which is a protocol change and needs a
`protocol-change/NNN.md`, not a page change. The owner ruled (2026-09-29,
issue #569) that Trace ships without timing bars: it lists the program's calls
in order from what the page already receives, plus the latest program's state
and result and the budget the call named. Per-call timing is a later
protocol change, after the redesign.

### 6.4 The Session tab

| Row | Source today |
|---|---|
| Goal | the page's goal read (`goal_view`), already sent |
| Jobs | `live_jobs`, a read the page does not send yet; it is read-only (`LiveJobsGet` is in the gateway's `read_only` list). `next.md`'s "attachment jobs stay terminal-only" is about the terminal's attach and relaunch jobs, not this read |
| Schedules | the schedule events the shared fold already keeps |
| Viewers | the presence roster in the cut |
| Estimated cost | `shared.usage`, see 2.1 |
| Cost by strand | per-strand usage; whether the ledger keeps per-strand cost is unchecked |

Viewers names the session's other principals. A terminal attachment sees the
roster, but #636 ruled that an observer page must not learn the owner's other
session names, on the reasoning that an observer link is handed to someone who
may only watch one session. The same reasoning applies to who else is watching.
The design shows viewers on operator pages only. This is a default the
orchestrator adopted, open to the owner's override.

### 6.5 The theme toggle

The toggle needs a place for the choice to persist, which is the storage
decision of section 4, and a way to set the theme that reaches the shadow
roots (section 5). It is optional for the first build. The page follows the
operating system's setting, which A2's screenshots also show.

Built as step 12: a Theme button that cycles the page through following the
system, light and dark, kept per browser under its own storage item
(`layout_rule`, protocol-change/051, the addendum on the storage decision).

## 7. Where each piece lives

`session_view` is shared with the terminal and holds no `@external`, so a rule
put there is portable and can be reused by the terminal revamp. `web_view`
lays out and draws. `web_client` holds what only the browser knows, and keeps
its decisions in `*_rule` modules that import neither Lustre nor `ffi_dom`, so
they run on Node 18.

| Piece | Package | Module |
|---|---|---|
| A strand card's name and one status line, the badge count | `session_view` | a new `strand_card`, from `agent_roster` and `agent_view.Status` |
| A strand's detail figures and recent list | `session_view` | `strand_card`, from the roster, the context board and the cache ledger |
| Files and hunks from the session's edits, with bounds | `session_view` | a new `changes_view` |
| Session summary rows, cost by strand | `session_view` | a new `session_summary` |
| Hit rate, if built | `session_view` | `cache_watch` or `cache_miss` |
| The shell, top bar, panel, cards, detail, tabs' panes | `web_view` | `view/shell`, `view/topbar`, `view/panel`, `view/strand_card`, `view/strand_detail`, `view/changes`, `view/trace`, `view/session_tab` |
| The sidebar | `web_view` | `view/sidebar` (#636) |
| The workspace digest for the storage key | `client` and `web_view` | passed in `component.Start` |
| Sidebar and tab state, the toggles, the marker relay, the keys | `web_client` | `<loom-shell>` over a new `shell_rule` |
| Decoding and encoding the stored layout, totally | `web_client` | `layout_rule` |
| The key set and where a key acts | `web_client` | `shell_rule.intent(key, code, modifiers, target, composing, handled)` |
| Storage read and write, a click on an element | `web_client` | new exports in `internal/dom.mjs` |
| Tokens and classes | `web_client` | `web_client.css`, built by `make gen-client` |

`layout_rule.decode` must be total: a stored value that is not the expected
shape, an unknown tab, or a missing field yields the default layout and never
an error. A value in storage is browser input, and it never reaches the
server, so its only effect is on the page's own presentation.

No rule about what a frame or a strand means is in `web_view` or
`web_client`. The card's status line is `session_view`'s, so the terminal can
draw the same words. Which regions are visible is `web_client`'s, because the
terminal has no such state.

## 8. The pull request breakdown

Each pull request is one feature or one fix, builds and passes `make check`
on its own, and needs the addendum named. Every pull request that changes what
the page draws is checked by a live drive of an operator's page and an
observer's page over a real session, with screenshots at 1440 by 900 in
light and dark, because the browser-side behaviour is outside `make check`.
The first three have no protocol content and go first.

The order assumes #635 and #636 have landed.

1. **Tokens and typography.** The palette of section 5, the new tokens, the
   user bubble and card styles, and the contrast check. No structure moves.
   Addendum: none. Proof: `make client-check`; the contrast check; screenshots
   of today's page in both themes against the A2 screenshots.

2. **The three-column shell.** The top bar, the left column (the #636
   sidebar), the centre and the right column holding the strand cards where
   the strip was, with no collapse and no tabs. The panel is the page's last
   child. Updates every pinned path. Addendum: none. Proof: the updated `page_events_test`, `ui_socket_test` and
   `focus_test`; a drive showing focus works from the moved cards on both
   pages; screenshots.

3. **Collapsible sidebars.** `<loom-shell>` with the two toggles and the slots,
   no persistence and no keys. Addendum: none. Proof: `shell_rule` tests on
   Node 18; a drive checking hidden regions are not focusable; the "both
   hidden" screenshot.

4. **The tabbed panel with Strands and Session.** Tabs in the shell element;
   the Strands tab with the badge and the needs-approval status line; the
   Session tab with the rows whose data exists (goal, schedules, cost).
   Changes and Trace are not shown until they have content. Addendum: none.
   Proof: tab rules on Node 18; simulator tests that the panel carries no
   decision control; a drive with a pending approval, showing the card in the
   dock and the strand's status in the panel.

5. **The timeline and strand detail.** Dots, tags, the breadcrumb and links as
   marker controls; the relay in `<loom-shell>`; the detail view in the Strands
   tab. Addendum: the marker relay. Proof: `focus_test` for the
   list and detail; a socket test that an observer's click at any other path
   is dropped; a drive focusing each strand from each of the five places.

6. **The keyboard.** `⌘B`, `⌘⌥B` and `Esc`. Addendum: section 6.2. Proof:
   `shell_rule.intent` tests over the key set and every exclusion; a drive in
   Firefox, Chrome and Safari; a test that no key sends a decision.

7. **Persistence of layout.** `localStorage` for the sidebars and the tab,
   the workspace digest in `component.Start`, and two new single-call exports
   in `internal/dom.mjs` (read an item, write an item), each wrapping its
   storage access in try/catch and returning a result, since storage can throw
   in a private window. They are bound in Gleam beside the existing DOM
   bindings, the same pattern as the minimal DOM binding. The per-workspace
   key, the encoding, the total decoding of the saved layout, and the defaults
   when nothing is stored or it fails to decode are all Gleam in `layout_rule`.
   Addendum: the storage decision, including that `web_client_js_check.sh`
   keeps refusing any storage use outside `dom.mjs`. Proof: `layout_rule` tests
   on Node 18 (default on nothing stored, default on a malformed value, an
   unknown tab); a drive reloading the page and reopening in a new tab.

8. **The todo line.** The one-line collapsed form of the todo panel, with the
   strand's focus. Addendum: none. Proof: `todo_panel` tests; screenshots.

9. **Changes from the session's edits.** `session_view/changes_view` and the
   tab, bounded. Addendum: none. Proof: `changes_view` unit tests with a
   markup-bearing patch checked as escaped text (as `web_view_parity_test`
   does for the transcript); a size test; a drive.

10. **The Session tab's remaining rows.** Jobs (a new read-only `live_jobs`
    read on the page's tick) and viewers on operator pages. Addendum: none for
    jobs; the viewers ruling for observers if the owner rules to show them.
    Proof: `session_summary` tests; a drive with a background job.

11. **Session switching.** (Built: 051's addendum on switching sessions, with
    `session_isolation_test` for the invariant of section 3.4.) The planned
    follow-up, operator pages only, with its addendum. The redesign adds the invariant of section 3.4 as a test that a
    page for one session holds no text of another. Proof: the follow-up's own,
    plus that test and a drive switching between two sessions with a pending
    approval in each.

12. **The theme toggle.** After the decisions of sections 5 and 6.5. Proof: a
    drive in both themes and inside each shadow root.

The 051 addenda in this series are those of steps 5, 6 and 7, plus the one the
session-switching follow-up already carries.

Settled strands in the list are their own pull request after this redesign
(owner, 2026-09-29, issue #569), not part of step 5. Per-call timing for
Trace, a later protocol change, also follows the redesign. One item is not
built and has no owner ruling: the composer target menu of section 3.3.

## 9. Where this note departs from the mockup and from earlier notes

From the mockup:

- The approval card stays in the dock (sections 2.3 and 6.1). The panel has no
  decision control.
- The advisor card has no `Deliver` or `Dismiss` buttons (owner, 2026-09-29,
  recorded on issue #569).
- Dots are not buttons or tab stops (section 3.1).
- Focusing `main` is `All strands`, and `main` has no detail view (section
  3.2).
- The composer has no typing indicator and no target menu (sections 2.3 and
  3.3).
- The sidebar has no `New session`, `Goals`, `Jobs` or `Scheduled`, and no
  strand bars for other sessions (section 2.2).
- Neither the viewed session nor the focused strand is persisted (section 4).
- The `ctx` figure keeps its tilde (section 2.1).
- The approval arming delay is 600 ms, not the mockup's 2 s.
- The mockup's session switch left the Changes, Trace and Session tabs showing
  the old session; here every region follows (section 3.4).

As built in steps 4 and 5 (the tabbed panel, the timeline and the strand's
view), where the build differs from the text above:

- The panel has Strands, Changes and Session tabs. Trace is not built, as
  section 6.3 rules. The Changes tab is always present: with no edit it holds
  its heading and a line saying so.
- The Session tab shows the goal, the jobs, the viewers (operator pages only)
  and the estimated cost. It has no schedules row, because the shared record
  keeps a schedule listing only as transcript lines the page does not draw.
- A marker's number is the card's position among the cards as drawn: the
  listed strands in order, then the advisor. `main` is always zero. Section
  3.1's "1 for the advisor" would have made the advisor's number depend on
  whether the strip held other strands; the position as drawn is one function
  for the cards and the lane (`strip.positions`).
- A card is a ring, a name and one status line. The figures moved to the
  strand's view: Model, Context, Cache (the words `cache_miss` allows, drawn
  where a card once drew them beside its ring) and Running. There is no Cost
  row, since the session keeps its cost as one total and no ledger of a
  strand's own. `Recent` lists the tools the strand ran lately, without ages,
  since `agent_view` keeps the names only.
- Dots and tags are drawn for the strands the transcript names (a spawn, a
  result, a nudge) and for the strand on screen as decoration. A piece that
  belongs to the strand on screen carries no marker, and a strand the page
  does not list is words and not a control.

From `web-ui.md`: the 280 px sidebar and the 56 px rail (section 2) become the
232 px sidebar; the 56 px agent strip and the warp margin (sections 2 and 3.1)
become the panel's strand cards and the single timeline; the right pane's
tabs (section 5) become Strands, Changes, Trace and Session, with the
inspector and replay left for later; and the token table (section 6.1) is
replaced by section 5 of this note. Its principles, the approval card rules,
folded work, the cache semantics and the multiplayer model stand.

## 10. Open questions for the owner

Ruled by the owner (2026-09-29, issue #569):

1. Layout state lives in the browser's `localStorage`, per workspace.
2. The focused strand is not restored across a reload; a reload shows `main`.
3. Settled strands in the list are a later pull request of their own, after
   this redesign.
4. Changes shows only diffs from the session's own edit tool calls, with no
   worktree read.

Closed by the tree:

5. What "All strands" shows: `main`'s rows plus the rows where other strands
   crossed in, which is today's projection. No new projection.
6. The viewed session: a page's address names its session and tickets are
   single use, so it is not restored.

Also ruled by the owner (2026-09-29, issue #569):

7. Trace ships without timing bars: the program's calls are listed in order
   from what the page already receives. Per-call timing is a later
   `protocol-change/NNN.md`, after the redesign.
8. The strand ring keeps the cache outlook (time before the cache expires),
   with no hit rate.
9. The left sidebar's strand bars show only for the session being viewed.
   Other sessions show name and resident or saved state, as #636 does, with no
   new data.

Defaults the orchestrator adopted, open to the owner's override:

10. No detail view for `main`. It would need a second piece of server state
    (which strand's detail is open).
11. Below a breakpoint the sidebars hide, with no overlay in the first build.
12. Viewers are shown in the Session tab on operator pages only.

## 11. Out of scope

The terminal client's revamp follows the first web UI version (owner,
2026-09-29). It will take this design as its reference and reuse the shared
`session_view` step and the modules this note adds there, and it is not
designed here.
