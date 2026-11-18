# Reference designs: Coordinator, Inbox and Plannotator Inbox

**Status: research input for the attention-inbox bracket, not a
commitment.** This digest records what three outside tools do, so the
design agents in this bracket argue from the same facts. It was gathered on
2026-11-15 from each project's public README or site. Where a page was
silent, this note says so rather than guessing.

The owner's prompt for the work: reading through transcript context to find
what matters is "a major drag"; the web UI should surface important items
directly, in the manner of these tools.

## 1. Coordinator (petekp/coordinator)

One agent session is turned into a manager for a body of work: a domain
such as a repository or product area. It delegates each task to its own
session and supervises it.

- **Delegates.** One session per task, each with its own Git worktree and
  branch, and a brief that says what "done" is and where to stop. A
  delegate writes a `REPORT.md` when it stops. At most three run at once;
  open PRs per repository can be capped.
- **Waking.** A background watcher wakes the coordinator when a delegate
  finishes, asks a question or gets stuck, and when a PR merges, fails
  checks or gets a review.
- **Status "by who acts next."** `fleet_status` groups the fleet by whose
  move it is, not by task or by time. Asked "where are we", the
  coordinator answers with a table of delegates, PRs and open questions.
- **Decision policy.** It decides small, reversible things itself and says
  what it chose. It asks when a choice changes what gets built, costs time
  or money, affects other people, or is a matter of taste. Questions come
  in batches of at most five, each with options and a recommendation.
- **Durable state.** A Markdown backlog (scope, approved, open, done) that
  survives a restart; per-delegate reports; a state directory for ended
  delegates and watcher state.
- **Cleanup.** A sweep removes finished worktrees, branches and stray
  processes, and refuses anything that would lose work, asking instead.
  Quiet delegates are ended after a day and resumed with the same session
  when new input arrives.
- **Silent on:** how the model or effort is chosen per task (the README
  does not say).

## 2. Inbox (petekp/inbox)

A panel beside the agent that holds "everything that needs a decision", so
a person does not hold a long thread in their head. Written explicitly with
ADHD readers in mind.

- **Tabs.** *Asks* (questions, and tasks only the human can do), *Finds*
  (bugs, risks and ideas the agent noticed outside its current task), *PRs*
  (Blocked, Ready or Waiting, with the blockers listed), and on the `next`
  branch a *Status* tab first: the current focus, each part of the work
  with how long ago it changed, the sub-agents under each part, a "where
  you last looked" line, and an optional goal with milestones.
- **How asks are found.** After each agent reply, a cheap model pass
  extracts questions and their possible answers from the reply, with the
  agent's recommendation first. The agent can also record items with a
  `record` tool and close them with `close`.
- **Answering.** Pressing an answer sends it as the user's message after a
  few seconds, with Undo. Other actions: type a reply, *Explain* (say more
  before I decide), *Compare* (the agent builds a side-by-side page leading
  with its pick; "Comparing…" until it reports, "No comparison came back"
  after 30 minutes).
- **Finds actions.** *Fix* / *Do it*, *File issue*, *Reply*, *Explain*,
  *Discuss*, *Dismiss*.
- **PR actions.** Address one or all review comments, draft a reply, fix a
  failing check, resolve conflicts, merge. Fix buttons appear only while
  GitHub still shows the problem. The agent can rank PRs into a merge
  order, with the reason.
- **Lifecycle.** Items close on their own when the user answers in their
  own words, a task is done, or the agent fixes a finding. Closed items
  fold under open ones, each saying how it ended. Dismissed items keep
  Reopen for the session. Every press shows its effect at once
  ("Discussing…" then "✓ Discussed").
- **Ambient signals.** A status line above the prompt counts what needs
  you and the waiting finds; a stop line appears when the agent halts on an
  error, with Resume after an API error.
- **Agent awareness.** The agent sees open items and recent answers beside
  each prompt, even after compaction.
- **Coordinator integration.** The coordinator's scripts read the inbox's
  saved questions, so delegates' asks reach one surface.
- **Silent on:** a formal schema, and how a child session's item reaches a
  parent's inbox.

## 3. Plannotator Inbox (backnotprop/plannotator)

"Your agents' questions, plans and reviews in one local window." Read
like mail and answered when you get to it.

- **Framing.** The agent's own window is for the run you are watching; the
  inbox is for the long runs you are not. "Nothing reaches the agent until
  you send."
- **Threads.** Every agent writes to it; each item is a thread with its
  context attached. The list is grouped "by what each one needs."
- **Item kinds.** Questions (with options, or picture choices), blockers,
  plans, prototypes (Markdown, HTML, Mermaid, Graphviz), design docs,
  diffs and guided reviews split into ordered sections each with its diff
  and summary, and media.
- **Responding by annotation.** Select text in a plan to delete it,
  comment on it, or replace it; numbered comments pin to parts of a
  document or prototype; comments travel with the next Send. Plans can be
  approved or denied with feedback.
- **Revisions.** When an agent resubmits, a badge shows lines added and
  removed and a diff view opens. If an agent edits a document after
  sending it, the inbox notes the change and opens the version that was
  sent — the same binding Loom's approvals make (consent binds to what was
  shown).
- **Receipts.** After a send, the thread shows "Delivered to" the agent.
- **Local and phone-friendly.** Listens on loopback, stores threads as
  files, and works on a phone over Tailscale.
- **Silent on:** sidebar structure, keyboard shortcuts, and the names of
  the groups.

## 4. What the three agree on

1. **The unit is the item that needs a person, not the message.** Each tool
   lifts asks, blockers, plans and reviews out of the stream and gives them
   a place that does not scroll away.
2. **Group by whose move it is.** Coordinator's "who acts next" and
   Plannotator's "by what each one needs" are the same idea.
3. **Every ask arrives answerable.** Options, a recommendation first, and a
   one-press answer; free text and "explain more" as escape hatches.
4. **Items have a lifecycle with receipts.** Open, answered or delivered,
   closed with how it ended, and folded rather than deleted.
5. **The transcript is a drill-down.** Context is attached to the item and
   opened on demand, never the thing you read first.
6. **Many sessions, one surface.** The value grows with the number of
   agents; a per-session panel is the degenerate case.
