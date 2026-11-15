# The attention inbox: a design bracket for the web view

**Status: exploration, not a commitment. The owner has given a direction
(section 2), and the questions in section 3 remain open.** Nothing in the web
view changes here.

The owner asked for a web UI in the manner of a coordinator and an inbox,
because "needing to read thru context is such a major drag vs surfacing
important items more directly". This directory is the bracket that answered
it: four concepts drawn from one brief, two critiques, one revision each, a
final ranking, and the owner's reaction.

## 1. How to read it

| File | What it is |
|---|---|
| [`00-fact-sheet.md`](00-fact-sheet.md) | What Loom already emits that an inbox could draw, marked EXISTS, PARTIAL or ABSENT, with citations |
| [`01-references.md`](01-references.md) | What Coordinator, the Inbox plugin and Plannotator's inbox do, and the six points they agree on |
| [`02-scenario.md`](02-scenario.md) | The one moment every mockup draws: the owner back at 14:20 with six sessions |
| [`03-brief.md`](03-brief.md) | The brief, its rulings, and the addendum that put project mode back in scope |
| [`04-critique.md`](04-critique.md) | The two critique lenses and how revision and ranking ran |
| [`concept-a.md`](concept-a.md) | A: the inbox is the home |
| [`concept-b.md`](concept-b.md) | B: the board by who acts next |
| [`concept-c.md`](concept-c.md) | C: threads you answer like mail |
| [`concept-d.md`](concept-d.md) | D: an attention layer on A2 |
| [`critique-owner.md`](critique-owner.md), [`critique-loom.md`](critique-loom.md) | The two critiques, written before revision |
| [`ranking.md`](ranking.md) | The final ranking, the decisions that hold whichever concept wins, and the cheapest test that would overturn it |

Each `concept-<x>/mockup.html` is a self-contained static page that opens
directly in a browser. All four take `?theme=dark|light` and `?frame=phone`,
and most take `?open=<item>` and `?view=projects`; each note names its own.
[`screens/`](screens/) holds the screenshots the critics and the ranking read,
at 1440×900 and 390×844.

The final ranking put A first, then D, C and B, and recommended a hybrid: A's
queue as the home page, with D's returned-state session page as the place a
Review press lands. Before revision, the owner-lens critic ranked A > C > B > D
and the Loom-fit critic D > A > B > C.

## 2. The owner's direction (2026-11-15)

Having seen the bracket, the owner said which parts they liked. Two did not
come from the recommended hybrid's spine.

- **C's threads, for review.** The thread version gave the owner the context
  they needed to review: the agent's last message, the diff in order, the
  finds marked at the lines they concern, and a send bar that names what goes
  to whom. ([`screens/c-open-item.png`](screens/c-open-item.png),
  [`screens/c-open-ask.png`](screens/c-open-ask.png))
- **The in-session view, for close monitoring.** When the owner is watching a
  session closely, they want the live-ish stream to stay, with overlays that
  lift out the useful insights and action points as they arrive. D's
  returned-state page is the nearest mockup
  ([`screens/d-desktop-light.png`](screens/d-desktop-light.png)). It is not
  the same thing, though: it folds the transcript to a bar, where the owner
  describes a stream that stays live with attention overlays on top. No
  mockup in this bracket draws that mode yet.

Read together with the ranking, the direction suggests a page with three
modes. The queue is for coming back. C's thread pane is for deciding with
evidence, reviews especially. The live session with attention overlays is for
watching. Whether the queue stays the home page (A) or gives way to the
thread list (C) is open, as section 3 says.

## 3. Open design questions

These are for the owner. Recommendations are the ranking's, or this note's
where marked.

1. **Where do you land when something is waiting?** The queue (A), the thread
   list (C), or the top item's session (D)? The ranking recommends the queue.
   The owner's liking for C's threads makes the thread list a live
   alternative: C's list is a queue grouped by need, with a reading pane
   beside it.
2. **Does the landing page replace the home page's new-session form?** The
   ranking recommends "only when something waits or runs", keeping the form on
   first run and when nothing waits.
3. **Are approvals decided only on their own session's page?** The ranking
   recommends yes, jumping to the real card, because a decision echoes the
   record's full action text, grants and sequence (`echo_matches` in
   `client/gateway.gleam`) and no row can show all of that.
4. **Is reviewing a diff part of this work, and when?** The ranking said not
   in the first three phases. The owner's direction pulls C's review pane
   forward, so this needs a new answer: which phase, and whether its first
   version reads worktree hunks only (as revised C does) rather than a new
   review record.
5. **What is the live monitoring mode?** (This note.) Do overlays sit over the
   stream or in a rail beside it? Does an item stay pinned until it is answered,
   or fold once read? Which kinds are lifted: asks, finds and approvals only,
   or also errors, check results and sub-agent results?
6. **How does project mode's "check failed" stage reach `main`?** The ranking
   recommends the raw stage word in phase 0, then the pure half of
   `project/visible-failures` re-cut onto `main` for phase 2. Neither depends
   on #1167's template question, which stays the owner's.
7. **The project meta layer is not designed.** (This note.) No concept draws
   the pieces of project mode taken from the DeepSeek super-agent prototype:
   - the router as the one agent you talk to;
   - the Mandate, which says why a piece of work is allowed;
   - `observe` and what the router would have accepted;
   - labels, a live verdict and `auto` per rule;
   - inferred work published only by a person;
   - the attention budget (acted-on against dismissed);
   - `project/project-settings`' proposals, such as a `check` proposed from
     the repository.

   Each is a decision only a person can make, so each is a natural kind of
   queue item. #1168 is where they reach the web. A follow-up note should map
   each to an item kind, its actions, its role gates and its phase, holding
   #1168's four unchanging rules.

## 4. What holds whichever direction wins

[`ranking.md`](ranking.md) section 7 has the full list. The short form:

- **Records.** Agents record an ask, a task or a find with a creation time, a
  routing field, a transcript anchor and the parent chain.
- **The classifier.** One "whose move is it" function lives in
  `session_view`, shared by the sidebar and the project board.
- **The feed.** It carries identities and heads, with content read per record
  at a revision.
- **Approvals.** An approval has no hold and no undo.
- **Holds.** Undo is a daemon-side hold.
- **Counts.** Every count says what it read. Today's activity read never sees
  saved sessions, so the first acceptance test of any build is a daemon
  restart with an approval pending.
- **Text the page may not write.** The page never claims a peer message is
  relevant or unanswered.

## 5. What the mockups get wrong

- **Press counts** do not separate the concepts. Armed like for like, they
  run 18 to 19.
- **Peer messages.** Three mockups say the 13:15 peer message is "about the
  same grant" or "not answered". Nothing in Loom can know that.
- **Wait times.** No phase-0 page can show them. The activity row carries no
  time, and an escalation's `asked` is a count, not a time.
- **Stuck delegates.** These are invisible today, because failure is judged
  from `main` only.
- **D's dock** shows a question from `runner/pod-reach` above a reply box
  addressed to `storage/branch-index-repair`
  ([`screens/d-open-item.png`](screens/d-open-item.png)).
