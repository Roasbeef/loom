# The design brief for the attention-inbox bracket

**Status: the brief every concept in this bracket was written from.** Four
designers each receive this brief and one *thesis* (section 6). They work in
parallel, and they do not see one another's work until the critique round.
The owner picks from the top of the bracket after critique and revision.

## 1. The problem, in the owner's words

> needing to read thru context is such a major drag vs surfacing important
> items more directly

The owner runs many sessions at once and wants to run more, in the manner of
a coordinator that delegates to sub-sessions. Today, to learn what a session
needs, the owner opens it and reads its transcript. The goal is a web UI in
which the things that need a person — a decision, a question, a review, a
stuck agent, a risk the agent noticed — reach that person directly and are
answerable where they appear, with the transcript as a drill-down.

## 2. Required reading, in order

1. `CLAUDE.md` (root): ground rules, especially pure packages, no naked
   `Bool`, and "the web view grows no session logic of its own".
2. `docs/design-notes/attention-inbox/01-references.md`: what Coordinator,
   Inbox and Plannotator Inbox do, and section 4, what they agree on.
3. `docs/design-notes/attention-inbox/00-fact-sheet.md`: what Loom already
   emits, marked EXISTS / PARTIAL / ABSENT, with citations. **Section 0, 5,
   7 and 8 are mandatory.** Build from these facts. Do not re-survey the
   tree; spot-read a cited file only when your design depends on the
   detail.
4. `docs/design-notes/attention-inbox/02-scenario.md`: the one moment every
   mockup draws.
5. `docs/design-notes/web-design.md` §1 (why the owner picked the calm
   concept A and then A2) and §5 (tokens). Skim the rest.

## 3. Rulings already made (do not reopen)

- **Calm wins.** In September the owner picked the quietest of three
  concepts because the other two "showed too much at once". A concept that
  surfaces everything at equal weight has failed the brief. Surfacing means
  ranking and folding, not adding panels. The A2 tokens and typography stay;
  no coloured left bars, no card shadows except floating surfaces.
- **One shared substrate, specified once.** Every concept may assume three
  additions exist by the end of its first build phase, and must say which it
  actually needs:
  1. **Attention records**: a model-callable tool family that records an
     *ask* (a question with up to five options and one marked recommended,
     or free text), a *task* (something only a person can do, with steps),
     and a *find* (a risk, bug or idea noticed outside the current task,
     with a severity), durably, per strand, as inert data with a total
     decoder. Records close when answered, done, fixed or dismissed, and
     keep how they ended. Approvals and `propose` are *not* replaced; they
     are other record kinds the inbox draws.
  2. **An attention classifier in `session_view`**: a pure function from a
     session's state to "whose move is it" — *you*, *agent*, *blocked*,
     *ready to review*, *quiet* — which both the terminal and the web view
     read. Today's "needs you" (a pending escalation, or main failed while
     idle) is its seed.
  3. **A daemon-level attention feed**: a push, across the sessions a
     principal may see, of record and classifier changes, so a page does not
     poll 24 sessions. This needs a `protocol-change/NNN.md`; name what it
     must decide, do not decide it.
  Concepts differ in what the person sees and does, not in inventing a
  different substrate. If your thesis needs something beyond these three,
  say exactly what and why, and put it in your cost section.
- **The coordinator already exists: it is project mode.** A router session,
  a worker session per ticket, a ledger, stages that say who acts next, and
  GitHub PR polling (fact sheet §2.5, §6). Build the coordinator story on
  project mode and on sub-agent strands. Do not invent a third mechanism.
- **Roles hold.** An observer sees counts and items but no control that
  decides; every deciding control is owner/operator only and uses the
  two-press arming pattern. Approval decisions bind to the escalation's
  digest and drawn sequence, never to transcript text.
- **No session text becomes markup**, and list keys come from daemon
  identities (fact sheet §5).
- **The phone matters.** The owner reads this over Tailscale on a phone
  (Plannotator's point). One phone frame is required.

## 4. What to deliver

All paths are under `docs/design-notes/attention-inbox/`. `<x>` is your
concept letter, lower case.

1. **`concept-<x>.md`**, the design note, 250–450 lines, in Loom's prose
   style (`docs/gleam-style.md` is for code; for prose follow the existing
   design notes: full sentences, no bullet dumps where an argument belongs).
   Sections, in order:
   1. *Thesis* — one paragraph. What the person looks at first, and why.
   2. *The owner's return* — a walkthrough of the scenario at 14:20: what
      they see, in what order, and every press it takes to clear the four
      items that need them, the review and the two finds. Count the presses
      and the screens. Then the phone.
   3. *Information architecture* — the regions, what ranks above what, and
      what folds. Where the transcript went.
   4. *Item anatomy and lifecycle* — what one item row and its open state
      show, its actions per kind, how it closes, receipts ("delivered to
      `main`"), undo.
   5. *The coordinator story* — how a coordinator session's delegates and
      their asks bubble to one surface, built on project mode and strands.
   6. *Mapping to signals* — a table: every item kind your design draws ×
      its source (fact-sheet section) × EXISTS / PARTIAL / substrate
      addition / NEW beyond substrate.
   7. *What changes where* — `session_view` vs `web_view` vs daemon vs wire;
      the protocol changes needed (names and what each must decide).
   8. *Roles* — what an observer and an operator see differently.
   9. *Cut list* — at least five things this concept deliberately does not
      do.
   10. *Build phases* — phase 0 must deliver visible value **with existing
       signals only** (no substrate). Then the phases after it.
   11. *Risks and the cheapest test that would prove the thesis wrong.*
2. **`concept-<x>/mockup.html`**, one self-contained static page: inline CSS
   and JS only, no external requests, no frameworks. It draws the scenario
   using the A2 tokens from the fact sheet §7, honours
   `prefers-color-scheme` and a `?theme=dark|light` query override, and has
   a `?frame=phone` override that renders the 390-px phone layout. Small
   inline JS for opening an item, tab switching and the arm-then-confirm
   press is welcome; the default view, with no interaction, must already
   tell the story.
3. **Screenshots**, taken with the pre-installed Playwright
   (`require('playwright')`, `chromium.launch()` with no options; do not
   install anything), at `deviceScaleFactor: 1`, written to
   `/tmp/claude-0/-home-user-loom/8cd7aa11-8c8d-5c06-9df8-446aa0000219/scratchpad/attention-inbox/concept-<x>/`:
   `desktop-light.png` and `desktop-dark.png` at 1440×900, `open-item.png`
   at 1440×900 with one ask opened, and `phone.png` at 390×844. **Look at
   each screenshot yourself** (Read the PNG) and fix what is broken before
   you finish.

## 5. House rules

- Write only inside your own `concept-<x>.md` and `concept-<x>/`. Other
  designers are live in the same directory. Never run `git checkout`,
  `git stash`, `git add` or `git commit`; the coordinator commits.
- No AI tool, model or vendor names in any file you write.
- Do not edit source code, the fact sheet, the references or the scenario.
  If the fact sheet is wrong where your design depends on it, say so in
  your final message with the citation.
- Your final message: the thesis in two sentences, the press count for
  clearing the scenario, the one thing your concept does better than any
  likely rival, its biggest weakness stated honestly, and the paths you
  wrote.

## 6. The four theses

Each designer gets exactly one. Push yours to its strongest form; do not
hedge toward the others, which exist so you need not.

- **A — The inbox is the home.** A cross-session queue of items, grouped as
  the Inbox plugin groups them (asks, finds, reviews and PRs, status), is
  the first and main page. A session is something you open from an item.
  The transcript is reached only through an item's context.
- **B — The board by who acts next.** The unit is the *agent* (session or
  delegate strand), not the item, and the page groups agents by whose move
  it is, as the coordinator's `fleet_status` does: *you*, *blocked*,
  *ready to review*, *working*, *quiet*. Asks and finds hang off their
  agent's card. A coordinator's delegates nest under it.
- **C — Threads you answer like mail.** Each item is a thread with its
  context attached, read and answered at the person's pace, in the manner
  of Plannotator: a list grouped by what each needs, and a detail pane that
  is a real review surface — plans annotated in place, a finished session's
  diff reviewed in ordered sections with the agent's summary per section,
  receipts on every send.
- **D — An attention layer on A2.** Keep the approved three-column A2 shell
  and its transcript-centred calm. Add the least that makes the drag go
  away: a cross-session "needs you" queue at the top of the left sidebar, a
  pinned "since you last looked" card above the transcript that lists what
  happened and what is asked, and items answerable in place in the dock.
  Win on cost and continuity.

## 7. Addendum (2026-11-15): project mode is unfinished, and it is part of this work

The ruling in section 3 that "the coordinator already exists: it is project
mode" was written from a stale handoff line calling it draft PR #1164. The
owner corrected the framing after the concepts were drawn: project mode is the
other half of this work, and it was started and not finished. Verified state:

- **#1164 merged on 2026-11-02.** Project mode is on `main`, opt-in through
  `loom project init`, and driven live on macOS with publishing off.
- **#1167, "make project mode first class", is paused by the owner** (since
  2026-11-05) on a concern that it was over-engineered. Three stacked branches
  are pushed and unreviewed: `project/warm-template` (a per-project template
  so a check can find its toolchain), `project/visible-failures` (a
  `person/check` stage, failures classified as environment or code, retry and
  recheck), and `project/project-settings` (settings held per project). The
  issue's open question, whether the template earns its cost or the owner's
  own tickets should simply check with network on, is the owner's to answer.
- **The web-page slice was never pushed.** Its first goal is "one project per
  major repo, run from the web page": create a project, post a request, and a
  ticket page with the diff, the check result and its failure output, and
  answer, recheck, retry, stop, close and publish.
- **Draft PR #1158** (`docs/web-ui-redesign`, unmerged) is an earlier web
  redesign proposal that also leads with a ranked queue of what needs a person,
  plus a restart receipt and a per-session digest. The project design note
  waited on it for its web navigation.

So the revision round must treat project mode as an unfinished surface this
work completes, not a finished one it leans on. Each revised concept says
where a project, its board and a ticket page live in its design; what of
#1167's web slice it absorbs and in which phase; and what it needs from the
paused stack (likely `visible-failures`, whose `person/check` stage is the
"stuck" signal a coordinator inbox needs). Concepts should not depend on
resolving the template question.
