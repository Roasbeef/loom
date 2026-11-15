# Attention inbox: fact sheet (what Loom already produces, and what it does not)

Read-only research against the tree at `/home/user/loom` (HEAD `b5fc93d`, 2026-11-15). No design is proposed
here. Every claim carries a path (`file:line`, or a doc section) that was opened. Marks: **EXISTS** (built
and reaches the page), **PARTIAL** (some of it exists, or it exists but does not reach the page as needed),
**ABSENT** (searched for, not there). Paths are relative to `/home/user/loom`; `wv/` = `packages/web_view/src/web_view/`,
`wc/` = `packages/web_client/src/web_client/`, `sv/` = `packages/session_view/src/session_view/`.

## 0. The seven findings that matter most

1. **There is no model-callable "ask the human" tool and no "finding" tool.** The only structured
   model-to-human records are: approvals (a refused call parked for a decision), `propose` (a durable
   suggestion queue), and, in project mode only, a worker's `project_report(status: waiting, question)`.
   See Q3.
2. **The home page and the sidebar already group sessions by "what needs you"** (Needs you / Working / Idle /
   Saved) from a polled `sessions.activity` read. But the page keeps only a four-word state and throws away
   the row's `last_message`, `glances`, `approvals` count and `model` (`client/daemon/server.gleam:6356-6390`).
3. **Project mode is already a coordinator.** One router session, worker sessions per ticket, a ledger, a
   board whose stages are literally "who acts next" (`person/answer`, `person/review`, `person/blocked`,
   `person/failed`), a worker question with an answer box, and GitHub PR creation and polling. The web home
   has a Projects section for it. It is owner-only, behind `[project]` config, documented as draft PR #1164
   (`docs/next.md:189`), and the web `Question` has an `options` list that the daemon always sends empty.
4. **No push exists across sessions.** `sessions.activity` is request/response, at most 24 sessions, one fresh
   read per call; the daemon "does not cache, poll, or push activity" (`protocol-change/050-session-activity.md`,
   Decision). The event bus has an `Escalations` topic but "nothing publishes a hint yet" (`docs/architecture/events.md`,
   "Who is on the bus today"). The projects board is polled every 5 s (`sv/project_board.gleam:59`).
5. **PR awareness exists only inside project mode.** Outside it Loom observes the Git working tree (files
   differing from HEAD, commits since base), never PRs, CI or reviews (grep of `session_view`, `web_view`, `tui`:
   only `project_board` mentions pull requests).
6. **Goals have no milestones.** One objective, a status (Active/Paused(cause)/Limited(cause)/Complete), a
   token budget and spend, an optional check command, and the reviewer's one note (`sv/goal_view.gleam:108-176`).
7. **Surprise for naming:** `sv/inbox.gleam` is a message buffer ("messages a host has received from one source
   and not yet reduced"), not an attention inbox. Do not reuse the name without a rename.

---

## 1. Current page inventory

### 1.1 What a browser gets

`loomd --ui` serves Lustre 5.7.1 server components plus a small client bundle; the browser holds no
credential and no session state (`docs/architecture/web-view.md` intro and "What runs where", lines 1-150).
One page = one lane to **one** session (a lane carries all strands' frames; the transcript shows one strand,
today `main` unless focused) (`web-view.md:7-18`). Pages are minted by `loom ui --session <id> [--operate]`
(`web-view.md` "Minting the link"). Roles: `observer` (default) or `operator`; without `--operate` even an
owner gets an observer page (`protocol-change/051-web-view-route.md:496-498`).

Four page kinds:

| Page | Component | Bound to | Notes |
|---|---|---|---|
| Observer session page | `wv/component.gleam` | one session | no controls except "Load older"; draws nudge card, no approval cards (`051:909-940`, `approvals.md` "Showing the question", `051:439`) |
| Operator session page | `wv/operator_page.gleam` | one session | composer, approvals, controls, Session tab sections |
| Home | `wv/home.gleam` | no session | the principal's sessions, projects, folders, new-session form, sign-ins |
| Admin | `wv/admin.gleam` | no session | owner-only: people, members, machines |
| Relayed session | `wv/view/relayed_session.gleam` inside `home` | one session on **another orchestrator** | owner's operating page only (`wv/home.gleam` header, protocol-change/094) |

### 1.2 Layout today (approved "A2")

Top bar 44 px; left sidebar 232 px; centre transcript at most 780 px wide plus a dock; right panel 340 px with
**six** tabs: Strands, Changes, Session, Trace, Notes, Evolution (`wv/view/panel.gleam` header; the A2 note
lists four, `docs/design-notes/web-design.md` §2, line 70-84, and is out of date). The owner picked concept A
over B and C because B and C "showed too much at once" (`web-design.md` §1, lines 35-68). Collapse state is
per workspace in `localStorage` (`wc/layout_rule.gleam`; `web-design.md` §10 item 1).

### 1.3 `wv/` modules (one line each)

Session page surfaces (`wv/view/`):

- `shell` page frame, three columns, sets `needing`, `waiting`, `proposals`, `evolution` badge attributes (`view/shell.gleam:162-224`)
- `heading` top bar: location, connection status, ctx% and est. cost; `context_breakdown` the ctx panel
- `sidebar` + `home_table` session lists grouped by need (see 1.4); `elsewhere` other orchestrators' sessions
- `lane` the transcript timeline; `fold_row`, `expansion`, `live`, `program_card`, `diff`, `code_view` row drawers
- `strip`, `strand_detail`, `peek` the Strands tab (one card per strand, status line, remote-child peek)
- `changes` (tool-edit diffs) and `worktree` (Git working tree, read by the daemon, owner/invited operator only; `wv/worktrees.gleam:1-30`)
- `trace` code_mode programs; `notes` strand blackboard browser; `evolution` governed-evolution board (approve/select/revoke, two presses)
- `session_tab` goal, live jobs, viewers, cost; `proposals`, `memory`, `remembered`, `peer_links`, `share`, `rename` Session-tab sections
- `todo_panel` the todo line/panel; `nudges` the advisor's undelivered nudges; `commentary` the advisor's commentary in the panel
- `controls` goal buttons and Fork form; `queue_input` held-message editor; `crumb` strand breadcrumb
- `projects` home Projects section and ticket page (`view/projects.gleam:1-30`); `create`/`new_session`/`folders`/`placement`/`resume`/`archiving` session lifecycle UI
- `admin_*`, `home_bar`, `signins`, `your_name`, `ended`, `notice`, `switch` account/admin/navigation chrome

Non-view modules: `component`, `operator_page`, `home`, `admin`, `page`, `sessions` (catalogue vocabulary and
`Activity`), `listing` (grouping), `orchestrators`/`relayed`/`relayed_lane`/`relayed_session`/`placements`/`machines`
(other orchestrators), `projects` (project board wire), `proposals`/`remembered`/`evolution`/`notes`/`peer_links`
(page-side state for those Session-tab features), `worktrees`, `tool_result`, `image`, `ending`.

Browser-side custom elements (`wc/`): `shell`, `switcher` (Cmd/Ctrl+K), `title` (tab title with a waiting count,
`wc/title_rule.gleam:37-41`: `"(2) ws · main — Loom"`), `fold`, `expand`, `follow`, `composer`, `attach`,
`popover`, `saved`, `link`, `mermaid`, `copy`, `time`, `elapsed`, `notes`, `reveal`, `switch`, `waiting`, `back`,
`dismiss`, `rename`, plus `*_rule` pure modules. These hold only behaviour that changes with nothing the server
knows (`packages/web_client/CLAUDE.md` Purpose). `wc/proposals_rule.gleam` is just the Session tab's screen-reader
words for a pending-proposal badge (`session_words(n)`), not a proposals engine.

### 1.4 The home page and the sidebar: do they show "needs you"?  **EXISTS (state word only)**

- Home (`wv/home.gleam`) lists the principal's catalogue entries grouped by workspace, refreshed every 30 s
  (`home.gleam:382`). After each list it starts an activity read for the running ones (`home.gleam` header,
  `Start.activity` at line 451, answered as `Observed(rows)` at line 971). A row's quiet line draws the activity
  word in `home-activity`, "the only part a needs-you row tints" (`web-view.md` home section, `home_table` row).
- The session page's sidebar draws the same list grouped **Needs you / Working / Idle** plus folded **Saved**
  (`wv/view/sidebar.gleam:1-14`; `wv/listing.gleam:107-121`, `bucket` at `listing.gleam:291`, quiet group folds
  after `idle_shown = 5`, line 52). It re-reads activity every 5 s for the rows it lists
  (`wv/component.gleam:490`, read started near `component.gleam:1939-1950`). The page's own session is read from
  its lane (`session_activity`), not the poll (`component.gleam:488-489`).
- A count of sessions waiting on the person is written as the shell's `waiting` attribute (max 10) so a phone
  shows a badge on the menu button while the sidebar is shut (`view/shell.gleam:189-203`).
- **NOTE (doc drift):** `web-design.md` §2.2 (line 140) says other sessions' rows carry no activity ("no new
  data is added", owner 2026-09-29, issue #569). The code has since grown the activity grouping
  (`listing.gleam` header). Trust the code.

### 1.5 How `sessions.activity` computes "needs you"

- Protocol: owner/member `sessions.activity`, 1 to 24 distinct canonical ids, one 2,000 ms deadline, rows
  `{session_id, state, strands, working, approvals, last_outcome, last_message(<=280B), model, glances[<=4]}`
  (`protocol-change/050-session-activity.md`, Decision; members answered only for held ids, Addendum 2026-10-04).
- `state = needs_you` when **any escalation record is pending, OR the main strand's last run failed and main has
  no current operation**; else `working` if any strand has a current operation; else `idle`; unknown word is
  `unknown` (same doc; implemented at `client/peer_mail.gleam:1519-1526`, words at `:1533-1537`).
- The page tells a failure from an approval by the `approvals` count: `needs_you` with 0 approvals becomes
  `Activity.Failed` (`wv/sessions.gleam:193-208` type, `:240-245` `activity_from`, words at `:254`). In the
  sidebar grouping `Failed` lands in **Idle** with its own colour (`listing.gleam:107-119`, `bucket` arm
  `sessions.Live, Ok(sessions.Failed) -> Idle`).
- **What is dropped:** the daemon reduces each row to `#(id, state)` before the page sees it
  (`client/daemon/server.gleam:6356-6390`, `state_of`). `last_message`, `glances`, `last_outcome`, `strands`,
  `working` and `approvals` (except as the failed-vs-needs test) never reach the page. The data to say
  "what each session last said" exists on the wire and is discarded at that closure. **PARTIAL.**
- Other signals in the catalogue row: `Residency` = Live/Saved/**Blocked** ("needs attention", recovery stopped)
  /**FailedStart(reason)**/Moving(to) (`wv/sessions.gleam:60-110`); `role`, `subtitle` (first prompt line, 60
  chars), `project` root. Cap: `activity_limit = 24` (`sessions.gleam:52`); `listed_limit = 100` sessions.

---

## 2. Attention signals, per kind

Legend for each row: **Origin** (package/module); **Durable?** store vs transient; **Reaches web?** frame type
(`sv/protocol.gleam` `Event`, lines 135-430) or read; **Scope** per-strand / per-session / cross-session.

### 2.1 Approvals and escalations  **EXISTS**

- Origin: broker refusal -> `client/escalate` -> durable `escalation/<id>` register (`runtime/escalation`);
  statuses Pending/Approved/Rejected/Consumed (`docs/architecture/approvals.md` "The vocabulary", 24-56).
  Sources: broker clearance refusal, a tool asking via `permissions` arg, code-mode launch refusal (`approvals.md:57-106`).
- Durable: yes (register). A parked call holds a run open only while an operator is attached
  (`approvals.md` "Several operators", `client/gateway.attached`); the count includes observers who cannot decide.
- Reaches web: via snapshot cells decoded by `sv/approval.gleam` (`records`, `decode`) and `EscalationPending`
  frame (`protocol.gleam:375-383`, carries id, tool, bounded untrusted preview). Per **session**, with `strand`
  from the record's `CallScope` (`approvals.md:261-299`).
- Who decides: owner and `Operator` members; any may answer and the first commit wins (compare-and-set on the
  register seq); an observer's page "draws no cards" and the gateway refuses `approve`/`deny` from observers
  (`approvals.md` "Deciding", "Several operators").
- What the card binds to: escalation id + register seq + the **action digest** + the wanted grants echoed back;
  the gateway checks the echoed action equals the stored digest ("binds the stored record to what the human was
  shown") and every grant is in `wanted` (`approvals.md:300-346`). Lifetimes: once / for the session (owner's
  page only, `approval.rememberable`) / deny.
- Card rules on web: pinned dock directly above the composer, 600 ms arming delay, 35% height cap, Deny first,
  never takes focus, Enter never decides, buttons name the tool (`approvals.md` "Showing the question";
  `web-design.md` §2.3 dock; `protocol-change/051` "The approval card", lines 669-700).
- Cross-session: only a **count** (needs_you) on home/sidebar. A pending request in another local session is not
  viewable or decidable from this page; the owner must open that session. Exception: **relayed** sessions on
  another orchestrator carry up to 8 `Need`s per row (escalation, seq, strand, tool, question, grants) and the
  owner's page can decide them if the spawner's approval ceiling admits it (`wv/relayed.gleam:55-130` `Activity`,
  `Ability`, `Need`, `Row`; `client/remote_top.gleam` page rule: 64 rows/64 KiB, requests cut to a row bound).
- Children on another orchestrator: their pending requests are mirrored into a session cell
  `remote-escalation/<orch>/<id>` and decoded into the same `Review` (`sv/approval.gleam` header; `approvals.md:447`).

### 2.2 Failed / stopped / blocked runs, provider errors  **PARTIAL**

- A strand's status vocabulary: Working, Waiting (provider retry or deferred-response wait), NeedsInput,
  Finished, Failed, Halted (idle with retained input or aborted), Idle, Unavailable (`sv/agent_view.gleam:53-80`).
  Card words come from `sv/strand_card.gleam:50` (`status_line`; `NeedsInput` -> `"Needs approval"`, line 53).
  `strand_card.needing` counts strands needing a person (`strand_card.gleam:252`) and feeds the Strands badge
  and the tab title.
- Run outcome: `completed`/`failed`/`aborted` of main's last run is in the activity row (`last_outcome`, 050)
  but not on the page's sidebar (see 1.5). A transcript `Failure`/`ToolFailure` row exists (`sv/transcript_line.gleam:54-55`);
  `ServerError` frame (`protocol.gleam:385-392`) becomes a one-line notice (`wv/view/notice.gleam`).
- A cache miss draws a dashed line (`sv/cache_miss.gleam`; `web-design.md` §2.3 table). No rate-limit,
  quota or provider-outage alert exists as a first-class signal (grep `rate.limit` in `session_view`: only the
  GitHub-source note in `project_board.gleam:211`).
- Session-level: `Blocked` and `FailedStart(reason)` residency rows (`sessions.gleam:60-110`).
- Scope: per strand (status) and per session (activity word). Durable: operation results are in the store;
  `Waiting`/`Failed` are projections of it. The failed-run flag is ephemeral in the sense that it clears when
  anything new starts (`peer_mail.gleam:1519`: only while "main has no current operation").

### 2.3 Advisor nudges and verdicts  **PARTIAL**

- The advisor is a second strand reviewing the primary; verdict is `quiet | nudge | block`, a built-in `advise`
  tool; nudges queue until the primary is idle, blocks go to the primary now (`docs/architecture/advisor.md:1-31`).
  The audience is the **primary model**, not the human; durable state is two reserved session cells.
- Web: `AdvisorPendingSnapshot(board)` (`protocol.gleam:199`) drawn as a text-only "pending nudges" card on both
  pages, no accept/dismiss, because the wire has only the read-only `advisor_pending` and the next run start is
  the drain (`web-view.md` "What is not built yet", lines 2234-2245; `wv/view/nudges.gleam`;
  `sv/advisor_pending.gleam:1-30`). The advisor's commentary shows in the panel (`wv/view/commentary.gleam`,
  `sv/advisor_history.gleam`), not in the lane (`051` addendum 2026-10-02).
- Goal path: the advisor also issues `continue`/`complete` for goals (`advisor.md:41`). Per session.

### 2.4 Goals  **PARTIAL (single objective, no milestones)**

- `Board = NoGoal | Pinned(status, because, objective, token_budget, tokens_used, cost_used, continuations,
  created_ms, updated_ms, reviewer_note, check, last_check, observed_at_ms)`; `Status = Active | Paused(by:
  ByOperator|ByAbort|ByZeroProgress|ByUnresponsiveReviewer) | Limited(by: ByTokenBudget|ByContinuationCap) |
  Complete` (`sv/goal_view.gleam:61-176`). `because` is the server's own sentence for the pair.
- Durable (goal register, `docs/architecture/goals.md` "Durable state"); reaches web as `GoalSnapshot`/`GoalChanged`
  (`protocol.gleam:214-218`) into the Session tab (`wv/view/session_tab.gleam`) and, on operator pages, a goal row
  with Pause/Resume/Clear buttons (`051` addendum "session controls", line 1880+; `wv/view/controls.gleam`).
  Per **session**; one goal per session. "Milestones" are ABSENT: grep of `packages/*/src` and `docs/architecture`
  found no milestone concept for goals. The check command's last run (`CheckRun`: exit status, tail, time) is the
  closest thing to progress evidence (`goal_view.gleam:180-194`).
- Cross-session: none; an unhealthy goal (Paused/Limited) does not feed the activity word.

### 2.5 Project mode  **EXISTS (owner only, config-gated)**  See also Q4 and section 6.

- Engine: pure `packages/project` (`engine.apply` takes an event, returns state + effects). One actor per project
  persists to a ledger and performs effects (`docs/architecture/project-mode.md` "Components", "Commit, then perform").
  Roles: router session (tools `route`, `project_read`, `reply`) and worker sessions per ticket (tools
  `project_report`, `project_handback`) (`packages/tools/src/tools/project.gleam:53-83`).
- **Stage = who acts next**, computed, never stored: `ended/<outcome>`, `person/delivery`, `person/answer`,
  `person/review`, `person/blocked`, `person/failed`, `queued`, `idle`, `working` (`project-mode.md` "A ticket's
  life"; decoder `sv/project_board.gleam:66-100`; anything spelled `person/...` counts as needing a person).
- Worker reports: `progress | waiting(+question) | blocked | failed | dropped` (`tools/project.gleam:773-856`;
  a question is allowed only beside `waiting`, `max_note_chars = 500`, lines 61-62, 841-845).
- Web: home Projects section, "what is waiting on me in my projects?" Stage groups, most urgent first, then a
  ticket page with the worker's question and an answer box, Close, link to the worker session
  (`wv/view/projects.gleam:1-30`; `wv/home.gleam:723-745` `Projects(boards, ticket, answer, close)`; mounted at
  `projects_path = "0\t2\t0"`, `home.gleam:353`). Board polled every 5 s (`project_board.refresh_ms`).
- Per ticket: `id, title, stage, session, mandate(strength, via, source, actor, policy_version), opened_ms,
  question{seq,text,options}, pull_request, failure, actions[CanAnswer|CanClose|CanRetry|CanPublish|CanStop]`
  (`sv/project_board.gleam:107-189`). Board also carries `would` (what `observe` rules would have done), `rules`
  with verdicts, and source `notes` such as a rate-limit end time (`project_board.gleam:191-217`).
- Gaps: `options` is decoded but the daemon writes `"options": []` always (`client/daemon/project_host.gleam:3755-3766`),
  and the worker tool has no options or recommendation field. Durable: yes (ledger). Not wired: `token_ceiling`
  has no consumer (`project-mode.md` "Known gaps"). Status: documented as draft PR #1164 (`docs/next.md:189-212`);
  "never run" lists publishing against real GitHub.

### 2.6 Proposals  **EXISTS (a model-to-human durable queue)**

- `propose` tool: the model suggests a standing rule (`loom-rules.md`) or an edit to the session's `loom.toml`
  (`kind: config`); it "never blocks, never raises an approval", returns `queued as <id>`
  (`packages/tools/src/tools/propose.gleam:1-40`; `docs/architecture/approvals.md` "Proposals are not approvals", 602-646).
- Durable rows under `proposal/` in the domain memory store; states pending/approved/rejected/stale; at most 64
  pending, newest 100 decided kept. Only the owner decides (`proposals_get`, `proposal_decide`). Per **domain**
  (workspace), shown in whichever session's page is open.
- Web: `ProposalsSnapshot` (`protocol.gleam:227`); Session pane section with a red/green diff, two-press approve
  (`wv/proposals.gleam:1-26`, `wv/view/proposals.gleam`); the `proposals` count attribute badges the Session tab
  on the daemon owner's page only (`view/shell.gleam:206-213`; `wc/proposals_rule.gleam`); refreshed by the
  daemon's `proposals_changed` push plus a 60 s backstop (`wv/proposals.gleam:28`). This is the one **pushed**
  human-decision signal besides approvals.

### 2.7 Governed evolution (candidate extensions/programs/prompts)  **EXISTS (owner/operator)**

- A session proposes an extension, program or prompt; a person approves and selects it as the generation the
  session runs (`wv/evolution.gleam:1-30`; protocol-change/099). Two-press confirms; board via
  `EvolutionSnapshot` (`protocol.gleam:242`); candidate count rides the `evolution` attribute on the tab
  (`view/shell.gleam:215-226`). Durable (audit journal). Per session scope; owner sees all.

### 2.8 Background jobs and code-mode executions  **PARTIAL**

- `LiveJobsSnapshot(board)` (`protocol.gleam:195`; `sv/live_jobs.gleam`: "an explicit current read... Missing
  or refused observations stay unavailable instead of becoming zero") into the Session tab (`wv/view/session_tab.gleam`).
  Transient/pulled per session. A finished job wakes the **model** via the job actor (`client/jobstate.gleam:72-78`;
  `docs/design-notes/async-completion-wake.md`), not the human. No job-finished item reaches an inbox.
- Code-mode programs: `ProgramRunning/ProgramFailure/ProgramSettled` rows (`sv/transcript_line.gleam:89-103`),
  Trace tab, `program_card`.

### 2.9 Sub-agents (strands `sub:*`): spawn, result, ask-parent  **PARTIAL**

- Tools `agent_spawn`, `agent_wait` (array of handles, one deadline), `agent_send`, `agent_roster`, `agent_note`,
  `agent_notes` (`packages/tools/src/tools/agent.gleam`, names at lines 2199-2430 and spawn/wait consts). Addressing
  rule: a strand may wait only on a descendant and address only its parent or a descendant (`agent.gleam:90-100`).
  A child cannot get an answer from a parent that is inside `agent_wait` ("designed-in hole", `agent.gleam:111-114`).
  The prompt tells children "Send a message when someone has to act on it now" and to put results in their final
  answer if the parent run has ended (`packages/prompt/src/prompt/default.gleam:173-186`).
- Web: Strands tab, one card per strand with status line (`view/strip.gleam`, `sv/strand_card.gleam`), strand
  detail, `StrandMessage` rows for a sibling's message (`transcript_line.gleam:62-68`), spawn row/result card in
  main's transcript ("a sub-strand's brief: one line with its state", `web-design.md` §2.3). Remote children on
  other orchestrators: `RemoteChildrenSnapshot` + peek (`protocol.gleam:186-192`, `wv/view/peek.gleam`).
- Durable: spawn briefs, results and strand state are in the store; `StrandResult` is a bus hint that nothing
  publishes yet (`events.md` bus table). Scope: per strand, across strands of one session. The Strands tab badge
  counts strands in `NeedsInput` (approval-bound), not "child finished" or "child asked".
- The design note's mock status lines `Asked 1 question` and `1 nudge pending` are **not implemented**:
  `strand_card.status_line` has no such arm (`strand_card.gleam:50-96`; only fixed word is `Needs approval`).

### 2.10 Cross-session peer messages  **PARTIAL**

- `peer_roster`, `peer_describe`, `peer_send` tools (`packages/client/src/client/peers.gleam:830-885`): a
  directional peer link authorizes messaging, with a separate permission to wake an idle strand; the receipt
  proves durable admission only (`docs/architecture/async-collaboration.md` "Peers have separate authority", 182-208).
- Received message is a `PeerMessage` transcript row with `PeerOrigin(session, strand)`, heading ends
  `origin_checked` (`sv/transcript_line.gleam:70-75`). The web page draws a `Reply to this peer` button that only
  drafts text for the operator to send (`051` addendum 2026-09-29, "Peer reply"). Owner's Session pane manages
  peer links (`wv/peer_links.gleam`, protocol-change/077). `peers.inspect`/`peers.send` exist as owner control
  commands (`client/daemon/server.gleam` command list).
- No "unanswered peer question" state exists; a peer message is just text in a transcript.

### 2.11 Worktree diff, changes, Git  **PARTIAL (working tree only; no PRs)**

- Changes tab: (a) diffs folded from the session's own edit tool calls (`wv/view/changes.gleam`) and (b) the
  daemon's bounded observation of the session's Git working tree: files differing from HEAD and commits since
  the base (`wv/view/worktree.gleam`, `wv/worktrees.gleam:1-30`, `sv/worktree_view.gleam`; `WorktreeSnapshot`,
  `protocol.gleam:174`). Read at open and again after a finished tool call, at most once per 4 s
  (`worktrees.refresh_ms = 4000`, line 43). **Not shown to observer pages**; owner and invited operators only.
  This reverses the owner's 2026-09-29 ruling in `web-design.md` §6.3 and §10 item 4 (the 2026-10-05 "Changes
  tab reads the worktree" addendum, `051` line 4177).
- "Git observation" in `docs/next.md:116` means this worktree read plus project hooks and goal checks, which are
  "refused on an untrusted executor" (slices 3-4 of protocol-change/109). It is not PR observation.
- PRs: only project mode. The host pushes a branch with `git push --no-verify` and uses `gh` to find or create a
  PR on `project/<ticket>`; a poller reads GitHub issues, comments, review comments, default-branch CI and up to
  20 watched pulls; merged/closed pulls become `Concluded` (`project-mode.md` "Done means verified", "The GitHub
  source"). Only a pinned `github.com` origin is read. A ticket row carries `pull_request: Option(String)` (an
  address, no state); stage `person/review` includes "a pull request open on a ready or published ticket".
  CI/review/mergeability state for a PR is **ABSENT** as data; a CI failure arrives as an inferred trigger to the
  router (`project-mode.md` "From a trigger to a ticket").

### 2.12 Held inputs  **EXISTS (per strand, transient)**

- Queue/steer messages held behind a busy strand; `QueuedInputSnapshot` (`protocol.gleam:171`), editor
  `view/queue_input.gleam`; memory-only by design (protocol-change/038); a draining daemon returns a held prompt
  with `HeldInputReturned` (`protocol.gleam:416-428`), "the only surviving copy".

### 2.13 Notes (agent blackboard)  **EXISTS (free text, no severity)**

- `agent_note` writes one cell "under your own namespace... the write itself notifies nobody"; its description
  asks the model to distinguish "completed, pending, and blocked work" and "observed errors from suspected
  causes" (`tools/agent.gleam:2324-2340`). Web: Notes tab, key index and reader, per focused strand, read-only
  (`wv/notes.gleam`, `wv/view/notes.gleam`, `docs/design-notes/strand-notes.md`; `NotesSnapshot`, `protocol.gleam:168`).
  Per strand, durable. Nothing classifies a cell as finding/risk/question.

### 2.14 Other modules named in the brief

- **creations** (`wv/creations.gleam`): the answer/refusal words for creating a session from the home form; not an attention signal.
- **remembered** (`wv/remembered.gleam`, `sv/remembered.gleam`): the permissions an approval-for-session left, with who/when and a two-step forget; a standing-authority audit list, not an attention signal. `PermissionsSnapshot` (`protocol.gleam:222`).
- **relayed** (`wv/relayed*.gleam`): sessions on other orchestrators with `needs` (2.1).
- **evolution**: 2.7. **notes**: 2.13. **memory**: `MemorySnapshot` (`protocol.gleam:231`), owner-only Session section.
- **todo board** (`sv/todo_board.gleam`, `view/todo_panel.gleam`): the active strand's task list and reviewer band; progress evidence per strand.
- **btw** (`sv/btw.gleam`): attachment-local side conversations, outside the durable transcript.
- **cost/context/cache**: `UsageChanged`, `ContextSnapshot`, `cache_watch`; informational.

---

## 3. Does anything extract questions the agent asked, or accept structured ask/finding records?

**ABSENT** for the general case. Evidence:

- Model-facing tool names in `packages/tools/src/tools/*.gleam` and `client/peers.gleam`: `bash`, `fs_read`, `fs_write`,
  `fs_edit`, `grep`, `blob`, `cap`, `code_mode`, `job` (`job_poll/kill/send`), `working_directory`, `todo`,
  `context_remaining`, `history_search`, `schedule_create/list/cancel`, `remember`, `propose`, `advise` (advisor only),
  `agent_spawn/wait/send/roster/note/notes`, `peer_describe/roster/send`, project `route/project_read/reply`
  (router) and `project_report/project_handback` (worker), plus LSP/search tools. There is no `ask_user`,
  `ask_human`, `request_input`, `record_finding`, `report_risk` or similar (grep for those names and `question`
  in `packages/tools/src` and `packages/prompt/src` hit only the files listed in section 2 plus
  `prompt/default.gleam:195`).
- The prompt's only ask-the-human guidance is prose: "when it is ambiguous in a way that changes the outcome,
  ask one specific question instead of guessing at length" (`packages/prompt/src/prompt/default.gleam:193-196`).
  The question is therefore ordinary assistant text. **Nothing parses assistant text for questions.** A search of
  `session_view` for extraction of questions from assistant entries found nothing; `sessions.activity` only carries
  the last assistant text of main's last run, cut to 280 bytes (`050`, `last_message`).
- **Nearest existing structured records** (all single-purpose):
  1. Approval = "may I run this with these permissions?" (binary-ish, tool-bound, 2.1).
  2. `propose` = "I suggest this standing rule/config edit" (diff, owner decides, 2.6). The closest precedent for a
     model-emitted, durable, human-decided, push-refreshed, badged queue.
  3. `project_report(waiting, question)` = free-text question for a person on a project ticket, answered with a
     form; the answer echoes the question's `seq` (2.5). Options and recommendation: **ABSENT** (wire field exists, always empty).
  4. `agent_send` to parent / `peer_send` = text between agents; no "needs a human" marker.
  5. `agent_note` cells, free text (2.13).
- Findings (bugs, risks, ideas the agent noticed): **ABSENT** as a record or a tool. The `agent_note` description
  nudges toward "observed errors vs suspected causes" and "blocked" work only in prose.
- Tasks "only the human can do": **ABSENT** as a record. The nearest is a project `person/blocked` stage from a
  worker report (`blocked`).
- `todo` board exists per strand but items are the agent's own work plan (`tools/todos.gleam`, `sv/todo_board.gleam`), with no "owner: human" attribute.

---

## 4. Cross-session view

- **One page, one session.** A page is bound to one session by its key and tickets are single use; opening
  another session is a navigation to a new page, only for operator pages (`sessions.gleam` header; `web-view.md`
  "Switching sessions", line 894; `051` addendum 2026-09-29 "switching sessions", line 2481). The browser's
  focused strand is not restored across reload (`web-design.md` §10 item 2).
- **What spans sessions today**
  - The sidebar and the home: catalogue + activity words for up to 24 running sessions (1.4, 1.5). **PARTIAL.**
  - Home Projects section: the boards of every project the owner has, polled each 5 s, with tickets that need a
    person and an answer box that acts across the ticket's worker session (2.5). **EXISTS** (owner).
  - `wv/elsewhere.gleam` + `view/elsewhere.gleam`: the first page of every other orchestrator's sessions, owner's
    operating page only, each row information-only with a "Where" launch hint (`home.gleam` header,
    protocol-change/085). `wv/orchestrators.gleam`/`relayed*`: sessions the page started on another orchestrator,
    drawn with their transcript, with reply/stop/archive and **decide** (2.1). The sidebar lists them too, read on
    a timer of their own (`home.gleam` header). **EXISTS** for relayed sessions the spawner started.
  - Cmd/Ctrl+K switcher (`wc/switcher.gleam`) lists pages and sessions client-side.
  - Terminal: a cross-session picker with needs-you/working/idle filters and a details pane was the origin of
    `sessions.activity` (`protocol-change/050`, Problem); the TUI also has a project board screen
    (`packages/tui/src/tui/session_selector.gleam`, `project_screen.gleam`).
- **What does not exist for an all-sessions inbox**
  1. **No daemon-level subscription or push.** Control-socket commands are request/response; there is no
     `subscribe` in `server.gleam` (grep). Per-session pushes ride the session gateway (`session_socket`,
     `ui_relay`) one session per lane. The `loom_events` pg bus has seven topics including `Escalations` and
     `Strands`, but "nothing publishes a hint yet", and it is local to one node (`events.md` "The bus",
     "Who is on the bus today"). So an inbox is a poll (home 30 s, sidebar 5 s, projects 5 s) or a new design.
  2. **Activity read is capped and lossy.** 24 sessions, one fresh Agency call each; "records nothing about
     whether the operator has seen a session" (`050`, Cost). No seen/unseen, read/dismissed, or snooze state exists.
  3. **Pending approvals of other sessions are not listed, only counted** (and decided only for relayed rows).
     An inbox that shows approval content for local sessions needs a new read; the existing path is per-session
     snapshot cells over a lane.
  4. **Page capability is per principal and role.** A member sees only held sessions (`050` Addendum); several
     sections are owner-only (Projects, proposals, peers, memory, elsewhere, worktree for non-owner).
  5. **No per-item identity beyond approvals/tickets/proposals.** Asks, findings and tasks have no schema, id,
     lifetime or decide-command (section 3).
  6. `sessions.activity` row JSON is bounded to 2,400 B per row and 60,000 B per reply (`050`, Decision).

---

## 5. Constraints a redesign must respect

| Constraint | Statement | Cite |
|---|---|---|
| Web grows no session logic | What a frame means, catch-up, line projection and an operator's input on the wire are `session_view`'s. The page "grows no session logic of its own"; reviews hold the code to it. New derivations (e.g. attention classification) belong in `session_view`, which both hosts read | `docs/architecture/web-view.md:55-64`; `packages/web_view/CLAUDE.md`; `docs/architecture/client.md#the-client-engine-and-its-hosts` |
| `session_view` is portable | Held to R6: no `@external`, no `gleam_erlang`/`gleam_otp`, compiles to JS; it is the client's lane and projection used by terminal and web | `CLAUDE.md` Ground rules ("`session_view` is held to the same rule"); `docs/gleam-style.md` Part IV §5 |
| Roles | owner / operator / observer. An observer's page: no mutating controls, no event handler except "Load older", no approval cards; the gateway refuses mutations from an observer binding (two independent layers: type and role). Without `--operate` even an owner gets an observer page | `protocol-change/051:280-300`, `:439-545`, `:909-946`; `approvals.md` "Deciding" |
| Operator role cap | The page's role on the binding is the principal's membership role and nothing else; no second role source | `051:296-300` |
| Approval consent binds what was shown | A decision names the escalation id and the seq the card was drawn at; the echoed action digest must equal the record's; grants must be in `wanted`; stale seq answers `stale_approval`. The card draws from the record only, never transcript text | `approvals.md` "Deciding" (300-346); `051:669-700`; `sv/approval.gleam` header |
| Two-press pattern for anything that decides | Proposals, evolution, forget, delete, move: the first press arms a question holding the row as drawn, the second sends exactly that; a press never decides a row that was not on screen | `wv/proposals.gleam:1-26`; `wv/evolution.gleam:1-30`; `wv/remembered.gleam` |
| Nothing from the session becomes markup | Session content drawn only as text nodes; no `href`/`src`/class/key/handler built from it; list keys come from daemon-assigned identities; `unsafe_raw_html` never used; handler messages carry only what the server drew | `051:646-667`; `docs/lustre.md` §3 "Never build handlers or attributes from session content" |
| Only attached events arrive | Lustre dispatches a browser event only to a handler in the rendered tree; `ui_socket` admits an observer's click only at known paths (`older_path`, `home_path`, `strip_path`) and an owner's at `invite_path`, `rename_path`, `peers_path`, `remembered_path`, `projects_path`... Region **tree paths are load-bearing**, so moving a region needs the matching constant and test change | `wv/component.gleam` path constants (see `home.gleam:353`); `web-view.md` Transport; `docs/lustre.md` §3 |
| New routes/events/commands | The interfaces of spec Part 1 are frozen; changing one needs a `protocol-change/NNN.md` (the problem, what was considered, the decision, the cost; `001`, `006` precedent). Control commands such as `sessions.activity` were added as numbered proposals (050). A push or subscription across sessions would be one. 109 is the latest numbered range seen in `docs/next.md` | `CLAUDE.md` Ground rules; `protocol-change/050`; `docs/next.md:116` |
| Rule Zero | Model-influenced code never runs in the harness VM; the page and any inbox feed run in the daemon, so any "ask/finding" record must be inert data decoded totally, never interpreted or executed | `docs/loom-design.md:49`; `CLAUDE.md` Overview |
| Total decoders at every wire/durability boundary | Pure packages (`core`, `machine`, `prompt`) perform no I/O; every durability/wire boundary uses total decoders; unknown words are kept, not refused (e.g. `UnknownStage`, `UnknownPause`) | `CLAUDE.md` Ground rules; `sv/project_board.gleam:20-30`; `sv/goal_view.gleam:74-82` |
| Calm layout | Owner rejected busier concepts; A2 keeps the transcript central, collapse persisted per workspace, strands cards "name + one status line", a strand needing input shows only its status line in the attention colour; the dock holds approvals above the composer; no coloured left bars, no shadows on cards (only `shadow-float` for floating things) | `web-design.md` §1, §2.4, §5 ("owner, 2026-10-03") |
| Observer can see counts but not decide | Any inbox surface drawing decide buttons must gate them like approval cards (owner/operator only, 600 ms arming, never auto-focus) | `approvals.md:261-299` |
| No naked `Bool`, literate comments, lint R0-R22 | Module `////` prose, `///` on every public item, blank line above comments, bodies of at most about eight statements, `make check` is the gate (verify by its own exit code) | `CLAUDE.md` |
| Pure-state-machine pattern for UI state | State machines as functions; process machinery via weft; no hand-rolled timers/pollers | `CLAUDE.md` ("Process machinery goes through weft"); `docs/weft.md` |
| Region reads run off the runtime | Every list/read is a daemon task that returns at once and answers as a message, numbered so a stale answer is dropped (`reads`, `board_reads`); the runtime never waits | `home.gleam` header; `wv/home.gleam:723` doc |

---

## 6. Related facts a designer will otherwise rediscover

- **Existing badge attributes on `<loom-shell>`:** `needing` (strands needing a decision; also tab title count),
  `waiting` (sessions waiting, <=10, menu button on phones), `proposals`, `evolution` (`view/shell.gleam:160-226`).
  There is no badge for Asks, Findings, PRs, jobs, or child completions.
- **Tab title already counts the waiting number** (`wc/title_rule.gleam:41`), per session page.
- **Poll cadences:** home list 30 s (`home.gleam:382`); sidebar activity 5 s (`component.gleam:490`); Projects board
  5 s (`project_board.gleam:59`); worktree 4 s after tool completion (`worktrees.gleam:43`); proposals 60 s backstop
  plus push (`wv/proposals.gleam:28`); peers 15 s and remembered 30 s (`wv/component` docs); context usage deferred 30 s.
- **What a lane sees across strands:** every strand's frames (`web-view.md:7-18`), so a per-session attention
  classifier over `Event`s (approvals, `OperationChanged`, `Committed`, `ServerError`, `GoalSnapshot`,
  `ProposalsSnapshot`, `AdvisorPendingSnapshot`, `LiveJobsSnapshot`) has the data without a new wire, but the
  page is attached to one session at a time.
- **History/durability:** the conversation is a write-once store; approvals, goals, proposals and project tickets
  are durable; held inputs, advisor pending queue as drawn, live jobs board, worktree and context are pulled
  observations.
- **Remote/`distributed` sessions:** a child on another orchestrator mirrors its requests into the parent
  session's cells; the sidebar's relayed rows carry `needs` (2.1). Untrusted executors refuse "non-tool callers
  (project hooks, goal checks, Git observation, the worktree diff)" (`docs/next.md:116-118`).
- **Multiplayer:** several operators see the same pending request and the first decision wins; presence/viewers
  show on the Session tab for operators only (`web-design.md` §10 item 12; `approvals.md` "Several operators").
- **Name collisions to avoid:** `sv/inbox.gleam` (message buffer); `project` "inbox" in project-mode (a worker's
  queued entries, `project-mode.md` "A ticket's life"); `Inbox`/`inbox` in `terminal-attachment` model. `docs/design-notes/attention-inbox/` also holds `01-references.md` and `02-scenario.md` from other researchers.

## 7. Visual system (for mockups)

Source of truth: `packages/web_client/src/web_client.css` (`@theme` is dark; two light blocks follow and must
match, gated by `scripts/web_client_contrast_check.sh`); rationale in `docs/design-notes/web-design.md` §5. The
page follows `prefers-color-scheme` and a Theme button sets `data-theme` on `<html>`; every token is `inherit`
inside shadow roots (`web_client.css:72-96`).

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg` | `#141517` | `#f6f5f2` | page |
| `bg-raised` | `#1b1c1f` | `#ffffff` | cards, composer, chips (`bg-user` same) |
| `bg-sunk` | `#111214` | `#efede8` | left sidebar |
| `code` | `#212226` | `#f1efe9` | code blocks, diffs |
| `fg` | `#e8e6e1` | `#1d1c1a` | text |
| `fg-quiet` | `#9a978f` | `#6f6b63` | secondary text |
| `fg-faint` | `#66645e` | `#a29d92` | non-text marks only (fails text contrast) |
| `divider` | `#2b2d31` | `#e2dfd8` | 1 px hairlines and card borders |
| `current` | `#7c96ff` | `#3b5bdb` | main strand, focus ring, links |
| `signal` / `advisor` | `#f0a24f` | `#d9822b` (text `#975a1e`) | attention amber, advisor; **same value** |
| `peer` | `#a78bfa` | `#8b5cf6` (text `#764ed1`) | peer messages |
| `danger` | `#f06595` | `#d6336c` (text `#c02d61`) | failure, approval card border, `on-danger` `#141517`/`#ffffff` |
| `added` | `#51cf66` | `#2f9e44` (text `#237833`) | ok, additions |
| `added-bg` / `removed-bg` | `#1f4d2e` / `#4a1a29` | `#d3efda` / `#fce6ec` | diff backgrounds (the design note lists older dark values `#17301f`/`#3a1a26`; the CSS governs) |
| `strand-2..6` | `#3cc9b4 #a3b85a #4fb3e8 #d873c8 #e07a5f` | `#0f9d8a #7a8a3a #1a8fc4 #b0429f #c2502e` | per-strand hues; each has a `-text` variant for text on light |
| `pill-ok-bg`, `pill-wait-bg`, `pill-bad-bg` | `color-mix(added 12%)`, `(signal 14%)`, `(danger 12%)` | same | status pills |
| `shadow-float` | `0 1px 2px rgba(0,0,0,.4)` | `0 1px 2px rgba(0,0,0,.05), 0 4px 14px rgba(0,0,0,.05)` | floating things only (jump pill, drawer) |

Typography and shape: `--font-sans` system-ui stack (14 px body per `web-design.md` §5, "nothing changes"; session
rows 13.5 px, chips 12 px, status glyphs 11 px, ctx panel 13 px), `--font-mono` `ui-monospace` stack at 12 px;
no web fonts loaded. Radii seen in the stylesheet: 6 px (buttons, status pill), 8 px (session rows), 10 px
(chips, panels). Rules (owner, 2026-10-03): cards and rows carry **no shadow and no coloured left bar**; emphasis
is a tinted background plus a tinted hairline border; state glyphs are always paired with words so colour never
carries state alone; the approval card must not share a border token with any transcript row (`web-design.md` §5).
Existing "needs you" look: a needs-you row tints only its activity word (`home-activity`); the strand card shows its
status line in the attention colour. Existing widths: sidebar 232 px, panel 340 px (resizable, `--panel-width`),
transcript max 780 px; below 1212 px the sidebar is an overlay drawer, below 980 px the panel is a row of cards
(`web-design.md` §10, "The drawer ruling").

## 8. Gaps list, one line each (so a reader does not have to infer)

- ABSENT: model tool to ask the human (with options and a recommendation), to record a finding, to flag a human-only task.
- ABSENT: any parser of assistant text for questions.
- ABSENT: PR/CI/review state outside project mode; PR "blocked/ready/waiting" as data (only `person/review` and an address).
- ABSENT: goal milestones; goal health does not feed `sessions.activity`.
- ABSENT: daemon-level push or subscription; seen/unseen/snooze/dismiss state for any item.
- ABSENT: surfacing of `last_message`, `glances`, `last_outcome` on the page (they exist on the wire, dropped at `server.gleam:6356`).
- ABSENT: completion/ask signal from a child strand as a first-class state (only approvals mark `NeedsInput`); "Asked 1 question" status line is a mock only.
- ABSENT: a delegate-fleet "waking" coordinator for ordinary sessions: no session supervises other sessions today
  except project mode (router + workers) and the peer link/`agent_*` tools, which are model-driven.
- PARTIAL: advisor nudge (view only, no accept/dismiss, no command).
- PARTIAL: cross-session approvals (count only, decide only for relayed rows).
- EXISTS: approvals with digest binding; `propose` queue with push + badge; project board stages with answer box;
  home/sidebar needs-you grouping; tab title and `waiting` badge; governed evolution; relayed sessions' decide buttons.
