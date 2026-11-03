# protocol-change/106: projects, tickets and the trigger origin

**Status**: PROPOSED 2026-11-01, built on draft PR #1164. The owner accepted the design's
five decisions ([docs/design-notes/project-mode.md](../docs/design-notes/project-mode.md)); the
formats are accepted when that PR merges.
**Affects**: the core `Origin` type (Part 1.1) by one variant; the client control
protocol (Part 1.6) by new `projects.*` commands; `loom.toml` by
`[project]`; the catalogue by `catalogue_projects`; a new per-project ledger file.
**Raised by**: the owner's request for a default project mode.
**Builds on**: [048](048-async-collaboration.md) (peer origin and receipts),
[059](059-strand-message-origin.md) as the strand origin's precedent,
[094](094-cross-orchestrator-sessions.md) (top-level sessions with no parent),
[095](095-worktree-workspaces.md) (a worktree per session).

## Problem

A project needs three things no interface offers today. External text has to reach a
worker with an attribution no model can forge. Clients need a board without
reimplementing ticket state. And a session's standing, router or worker, has to
change how the registry treats it.

## What was considered

### Delivering external text as harness text (rejected)

Completion notices and schedules arrive as harness text in a user-role entry, which
needs no format change. It was rejected because the text in this case is hostile by
assumption, and it would read in the harness's voice in the transcript and in provider
rendering.

### Reading external text only through a tool result (rejected)

A worker could get IDs and read everything through `project_read`, and a tool result
is already understood to be untrusted. It avoids the Part 1 change. It was rejected
because a follow-up has to steer a running worker at its next checkpoint, and a steer
is a message. An ID alone costs the worker a read for every comment.

### A new session kind in the catalogue (rejected)

A `kind` column would name what's special about a router. It was rejected because a
typed projection over the project row gives the same exhaustive matching with no
change to session records, and delegates show a row can be the marker. The note's
"typed standing" section has the argument.

### A change doorbell now (deferred)

A contentless `projects.changed` event would spare clients a poll, and it would be the
first event on the control socket after `hello`. We start pull-only with a revision and
add the event if polling shows a cost.

## Decision

### The trigger origin

`core/message.Origin` gains one variant:

```gleam
TriggerOrigin(source: String, trigger: String, actor: String)
```

It encodes with its own tag, and a malformed one fails decoding as corruption, as
`PeerOrigin` does. Only the project engine's actor writes it, from the stored trigger
and never from tool arguments. Provider rendering fences the body and labels it with
the source and actor. Attribution isn't authority: no code reads this origin to grant,
widen or skip a check, the same rule that holds for `StrandOrigin`.

An owner's turn typed into a worker keeps its human `Origin`, and the ledger records it
by entry ID.

### Control commands

All are owner-only in the first version. Reads are classified by `read_only`.

| Command | Read | Meaning |
|---|---|---|
| `projects.create` | no | Create a project for a workspace, with its router session |
| `projects.list` | yes | The owner's projects, with their counts by stage |
| `projects.board` | yes | A page of tickets, needs-a-person first, with `revision` |
| `projects.ticket` | yes | One ticket with its Mandate, assignments, inputs and session ID |
| `projects.post` | no | Add an explicit trigger from the composer, keyed by a request ID |
| `projects.answer` | no | Answer a question, echoing its `seq` |
| `projects.stop` | no | A person's stop, which withdraws the Mandate |
| `projects.retry` | no | A new assignment for a stalled ticket |
| `projects.publish` | no | Publish past a failing check; recorded with the principal |
| `projects.requeue` | no | Queue a stored trigger for a fresh Eval |
| `projects.set_mode` | no | `off`, `observe` or `auto` for one source and rule; `auto` is refused without a current verdict |
| `projects.labels` | yes | The recorded triggers of a rule that want a label, with the labelled count |
| `projects.label` | no | A person's `accept` or `reject` of one recorded trigger |
| `projects.verdict` | no | Measure a rule's labelled triggers on a lane and record the finding |

### A ticket on the wire

```json
{
  "id": "t_01",
  "project": "p_01",
  "title": "Fix the flaky snapshot test",
  "stage": "person/review",
  "session": "s_01",
  "mandate": {
    "strength": "explicit",
    "via": "addressed",
    "source": "github",
    "actor": "roasbeef",
    "policy_version": "v7"
  },
  "check": {"commit": "abc123", "outcome": "passed"},
  "question": null,
  "pull_request": "https://github.com/owner/repo/pull/1",
  "ended": null
}
```

`stage` is one of `person/delivery`, `person/answer`, `person/review`, `person/blocked`,
`person/failed`, `queued`, `idle`, `working`, or `ended/<outcome>`. Clients display it and
never derive it. `question` is null or `{seq, text, options}`, and the answer echoes `seq`.
Unknown fields follow the forward-compatibility rule of `docs/client-protocol.md` section 1.5.
Each record is added to that document and checked against live frames before the slice lands.

### Configuration

```toml
[project]
check = "make check"
protected_paths = ["Makefile", ".github/**"]
max_workers = 4
token_ceiling = 5000000

[[project.source]]
kind = "github"
allow = ["roasbeef"]
bots = []
```

Every key is optional, and a project with no table has the composer as its only source and
inferred work `off`. `[roles].router` is added beside `advisor`, falling back to `subagent`
then `main`.

### Durable state

`catalogue_projects` holds the project's ID, workspace, router session, ledger path and state,
and the catalogue version moves by one. The ledger is one SQLite file per project with one writer:
triggers, threads, decisions, tickets, assignments, effect rows and the outbox's receipts. It is
never replicated. A worker's request key derives from `(ticket, assignment_seq)`. Durable decoders are total. The `project` package holds no I/O and is added to
the R6 list.

## What it costs

A Part 1 origin variant means a client that predates it fails a whole session that holds one, so
older clients must be stopped first, as with 059. That's the reason to land the reader before any
writer. Every new standing is one more arm at each registry site, on purpose. A second SQLite file
per project adds a store to back up and retain, and a state that crosses it and a session's store
can't commit atomically, so effects carry derived keys and the human-turn ledger is rebuilt from the
log. Reopening at boot narrows "discovery is not execution" for owner-written rows, and each router
adds a resident session's memory for as long as its project lives.

## Addendum: the owner's board on the web view (2026-11-01)

**Affects**: the home page's server component (`web_view/home`) and its socket
(`client/daemon/ui_socket`) by one capability, one admitted click region and two page
reads; `docs/client-protocol.md` section 3.32 by four commands. No new HTTP route, no
new WebSocket route, no content security policy change, no new event class and no new
daemon command beyond the four named below.

**The commands.** `projects.ticket` (a read), `projects.answer`, `projects.retry` and
`projects.requeue` finish the set the first version listed. `projects.answer` echoes the
question's `seq`, and an answer whose `seq` is not the ticket's open question is refused
`conflict` and records nothing. The board record gains `opened_ms`, the arrival time of the
ticket's opening message, or null; a client shows an age only from it.

**The page.** The owner's home draws a Projects section above its centre, and a ticket
opens as a pane of the centre. Both are part of the home's existing socket, so they add
no route. Their authority is the creation capability's own, stated here because each new
reach needs it written down:

| Reach | Who | How it is admitted | Checked again by |
| --- | --- | --- | --- |
| The section is drawn and the board is read | The daemon's owner, on a page minted to operate | `Start.projects` is `Some` only through `ui_socket.home_projects_capability` | `projects_for`, which repeats the owner check before it asks a project's actor |
| A click on a ticket's button | The same page | A `click` beneath `home.projects_path` (`0\t2\t0`) is admitted by the `Submitting` and `Administering` rights and not by `Browsing` (`home_event`) | The component honours the press only for a project and ticket in the boards it holds |
| A ticket is read | The same page | The press above | `ticket_read_for`, the owner check again |
| An answer is sent | The same page | A `submit` beneath `home.table_path`, which the owner's socket already admits for its other forms | `answer_for`: the owner check, then the project's actor, which compares the echoed `seq` with the open question |

An observer-ceiling page, a member's page and a page on a daemon with no project table get
no capability, draw no section and ignore the messages. A forged frame at the region is
dropped by the socket before it costs a render, and a forged message that survives it is
ignored by the component. The browser supplies one value, the answer's text, from a form
with exactly one field. Every ticket string is external text, passed through
`text_hygiene` once by `session_view/project_board` and drawn as a text node: no class,
attribute, key or address is built from one. The feed hands the page the daemon's JSON
untouched (`client/daemon/ui_projects`), so the page and the control command read one
body.

**Not built.** The change doorbell, `set_mode` and `publish` controls and the verdict view
stay out of the page; the ticket page has no control for them. (The host check, the pull
requests and the answer's relay were built later; see the addendum below.)

## Addendum: done means verified (2026-11-01)

**Affects**: `docs/client-protocol.md` section 3.32 by one command, three ticket fields and
one board field; `[project]` by three keys; the project ledger by two engine events and the
host records they need. No change to the jail, to any worker tool, or to the session wire.

**The commands and records.** `projects.publish` (owner only, recorded with the principal)
publishes a ticket's current commit past a failing or missing check, and is refused while
`publish` is off. A ticket gains `check` (`{commit, outcome}` once the host's check has judged
the head) and `review` (the host's sentence for why a ticket waits for a person). The board
gains `unrouted` on page zero: messages the router was offered three times and decided nothing
about, each with the text a person needs and a `projects.requeue` to offer it again. Nothing is
dropped on the way: an explicit message that ends there is that record.

**The configuration.** `check`, `protected_paths` and `publish` join `[project]` (see
`docs/configuration.md`). All three default to doing nothing outward.

**The events.** `HeadObserved` carries the host's reading of an idle worker's branch, with its
verdict on the protected paths, and `ReviewRequested` carries the host's reason for asking a
person. Both are written by the host and neither can be built from a model's output. The
engine asks for the first with the `ObserveHead` effect when a worker reports idle with no
open question; protected paths are decided before the check, so a head that touches one has
no check requested. `OpenPullRequest` is renamed `PublishBranch`, and a later commit asks for
it again so the branch and the pull request show the new head. `RelayAnswer` is gone: an
answer is delivered as a trigger by the same path as any input.

**What reaches the outside.** The host pushes `<commit>:refs/heads/project/<ticket>` to the
`origin` remote with the daemon's own credentials, without force and without the repository's
hooks, and speaks to GitHub only through `gh api` on the REST interface. A ticket's title is
the one model text in a pull request, and it is capped, stripped of anything that could
mention, link or reorder text, and prefixed with the ticket's id. The body is built from ledger
facts: the ticket, the commit, the check command's digest and the ledger entry of the run. The
host looks for an open pull request from the branch before it creates one.

**What it costs.** A check runs with the network off, and a toolchain that needs the network to
build fails its check until that is given a reason to be otherwise. This addendum originally also
listed a residual risk: the repository's `.git/config` was a file a worker's sandbox could write,
because a worktree shares its repository's configuration. The addendum below removes it.

## Addendum: a worker has a clone, not the owner's repository (2026-11-02)

**Affects**: where a worker's workspace is and what the host reads. No wire command, no ledger
event shape and no catalogue column changes, and no key joins `[project]`. A review reason,
`intake_refused`, joins the three the ledger already stores (`project/codec`).

**The problem.** A worker's workspace was a linked worktree of the owner's checkout, and the session
policy makes a linked worktree's Git directory writable, which is the owner's `.git`, with no mask
over its hooks, configuration, refs or objects. A worker that read hostile text could plant a hook or
a `core.hooksPath`, `core.fsmonitor` or `core.sshCommand` there, which the owner's next Git command
in their own checkout runs outside any jail, whatever `publish` says. It could alter another ticket's
branches and objects, which share a common directory. With `publish` on, the host's unjailed push
honoured a worker-written `remote.origin.url`, `pushurl`, `url.*.insteadOf`, `core.sshCommand`,
`credential.helper` or `http.proxy`. And `refs/replace/*`, `info/grafts` or an object swap could make
the protected-path diff and the check read different content from the tree the push shipped for the
same commit id.

**What was considered.** Filtering the configuration keys a worker may set (rejected: the list is
open-ended and each omission reopens the hole), masking hooks and configuration inside the owner's
`.git` while leaving refs and objects writable (rejected: `git commit` then cannot run, and objects and
refs remain a way to change another ticket), and changing `widening_linked_worktree` for every session
(rejected: a person's own linked-worktree session keeps today's behaviour).

**Decision.** No session of `Worker` standing has the owner's repository as its Git directory.

1. A worker's workspace is an independent clone the host makes under the state root,
   `projects/<id>/tickets/<ticket>-<seq>`, with `--no-hardlinks`, no alternates, and `origin`
   removed. Its `.git` is a directory inside the workspace, so `workspace_policy` adds nothing. The
   daemon refuses to build a worker session on a clone whose `.git` is not a directory.
2. Each project has a bare host repository, `projects/<id>/host.git`, written only by host code and
   masked in every session. Every host Git command in it runs with the system and global
   configuration off, replacement objects off and no redirecting variable set.
3. On `HeadObserved` the host fetches exactly the commit the clone's branch names into the host
   repository, in the sandbox with the clone read-only and `transfer.fsckObjects` on, and requires
   the host repository to hold the same commit id. A refusal, including a refused fetch, is a
   `ReviewRequested` with the reason `intake_refused` and the host's words.
4. The protected-path diff (`base...commit`, with `base` the owner's `HEAD` fetched into the host
   repository), the check's repository (cut from the host repository at the commit) and the push all
   read the host repository.
5. The push goes from the host repository to the URL that `origin` had in the owner's checkout when
   the project was created, pinned in the host repository and given literally on the command line,
   with no remote name. The owner's global Git configuration still applies to that one command, which
   is how their SSH and credential setup reaches it.
6. A clone that ends with its ticket is removed unless it has working-tree changes or any ref or `HEAD`
   naming an object the host repository lacks. Every ref is compared, so a clone that looks clean from
   the branch its `HEAD` names does not hide commits on another.

**What it costs.** A clone copies the repository's objects, in time and disk, once per assignment. The
host repository keeps every commit it takes in. A worker's jail can still read the other tickets'
clones, because a mask over a clone would refuse every call of a session that outlives it. The owner's
`origin` is read once, when the project is created, and a project created before this change pins it
the first time its actor starts. A kept clone's hooks and configuration are the worker's, so a person
fetches from `refs/tickets/<ticket>/<commit>` in `host.git` and does not run Git inside it. The
project's pinned URL lives in a file inside the host repository and not in a catalogue column: a
column would have been catalogue version 21 and a regeneration of the SQL modules, for a value only
the host reads.

## Addendum: the GitHub source (2026-11-02)

**Affects**: `[project]` by `queue_limit`, `attention_limit` and the arrays `source` and `rule`; the
client control protocol by `projects.set_mode`; the board by `would_have_done` and `sources`; the
project ledger by one host record kind for a source's note, one for a compaction's marker, and a
snapshot document that a start now reads. No change to a worker's tools, the jail or the session wire.

**The source.** The daemon polls one repository, the one the project's pinned push URL names, with
`gh api` on the REST interface and the owner's credentials. It uses no webhook, no notifications API and
no GraphQL, because the owner's GraphQL quota is shared by every agent running as the same user. A
pass reads new issues, issue and pull request comments, pull request review comments, failed check runs
on the default branch and on the head of each pull request a ticket opened, and whether those pull
requests merged or closed. A read position is a cursor per stream in the ledger, and a stream with no
cursor starts at the present. A `403` or `429` with `retry-after`, or with an exhausted
`x-ratelimit-remaining`, defers the next pass to the time the headers name; failures in a row double the
wait up to an hour.

**Every field from GitHub is untrusted.** The decoders are total. A trigger's id is a function of
GitHub's (`gh-i|c|r-<id>`, `gh-ci-<id>`), so a page read twice is stored once, and a thread is
`gh-<number>`. The sender is `Person` on `allow`, `ListedBot` on `bots`, `CiFailure` for a failed check
and `Unlisted` otherwise; `Owner` is never produced from GitHub. The agent's own account is dropped
before the engine sees it. A text is stored whole up to 32768 code points and handed to a session cut at
4000 with a pointer, and `project_read` serves the whole text. A trigger descending from a pull request
the project opened carries a generation one past its ticket's.

**Rules and modes.** A rule matches by literal strings, compared without case, in file order, whoever
the sender. Its first mode is its configured one, `observe` by default; a person's later mode, set by
`projects.set_mode`, survives a restart. `auto` is refused in words until a rule has a current passing
verdict, so a rule configured with it starts in `observe`. In `observe` an inferred candidate that
passes the gate and a rule goes through the router, and the engine records `WouldAccept` and does
nothing else. The board lists those under `would_have_done` for the owner.

**Overload.** `queue_limit` and `attention_limit` are the engine's existing per-source bound and its
needs-a-person limit. The engine gains one rule, a cap of 20 inferred triggers per actor per hour, after
which the actor's triggers are shed and recorded as shed. Shed work is counted on the board.

**Replies.** A router reply to a GitHub thread goes out as an issue comment only when
`[project].publish` is `pull_request`. It is an outbox row ordered per thread, its text is cut to the
purpose's word cap, and `@`, `<`, `>` and `#` are replaced so the text cannot mention, tag or reference.
A marker comment is searched for before posting, so a repeated row posts once. With publishing off a
reply stays the draft the board shows.

**Retention.** Once a day, and only after 200 events, the actor drops ended tickets and settled
triggers older than 30 days that nothing remaining names, writes the engine's state without them as a
snapshot, and has the ledger delete the events below it in one transaction. The snapshot also carries
the host records that still matter and, for each dropped trigger, its decision, the ticket it named, and
the ledger entry it arrived at. A start reads the snapshot and replays the events after it.

**What it costs.** An ended ticket older than 30 days cannot be resumed by a comment on its pull request:
the comment reaches the router as a stranger's. The ledger keeps at most 20000 decisions. A rule's
literals also match an unlisted sender's text, so a literal an owner writes is a literal a stranger can
type; the rule's mode is what limits the cost, and `observe` costs a router turn per matching comment up
to the actor cap. The poller runs one pass at a time, so a page of 100 items per stream bounds the rate
at which a flood is read.

## Addendum: the Mandate decides the jail (2026-11-02)

**Affects**: nothing frozen. No Part 1 interface, wire record or `loom.toml` key changes. The
worker's base policy, its escalation seam and its tool ceiling are now derived from the ticket's
Mandate each time its session is built (`client/project_jail`).

**What a Mandate sets.** An explicit Mandate gives the worker the owner's session policy unchanged. An
inferred one gives it the same policy with the network turned off. Approvals go to a person for an
explicit Mandate and for an inferred one whose admitting rule granted them, and are refused for the
rest: the worker's escalation seam is `escalate.none`, which writes no record, so nobody is asked and the
call settles in band. No worker holds a credential. The tool ceiling is the same at both strengths and
refuses the peer and `agent_*` tools.

**Registries only is enforced as no network.** The design note says an inferred worker reaches package
registries only. `NetworkProxy` with an allowlist can state that, but nothing enforces it:
`policy.narrow_unenforceable` turns every proxy into `NetworkOff` and the call is refused with a
narrowing, and `bash` asks for whatever network its base allows. A proxy base would therefore refuse
every shell command an inferred worker ran, including those that touch no network. Considered: building
the egress proxy sidecar, which is a separate piece of work; and mapping to `NetworkProxy` anyway, which
breaks inferred workers. Decided: map to `NetworkOff`, which both the broker and the jail enforce. It is
narrower than the note and never wider. What it costs is that an inferred worker cannot fetch
dependencies, so work that needs them reaches a person. `client/project_jail.registry_hosts` keeps the
list for the day a proxy can enforce it, and a test pins that the broker refuses a registry allowlist
for both strengths.

**Where it is read from.** The actor tells `project_book` each ticket's Mandate when it starts and again
before it starts a worker, because a session's builder runs while the actor waits for it and cannot ask
the actor. The Mandate never changes once the ticket exists, so this is a copy and not a second source of
truth. A worker's `set_config` takes no key that names a network, an approval route or a sandbox, and its
`active_tools` are held to the ceiling, so nothing the worker sends changes the jail.

## Addendum: the verdict (2026-11-02)

**Affects**: `docs/client-protocol.md` section 3.32 by `projects.labels`, `projects.label` and
`projects.verdict`, and by a `verdict` object on each rule of the board's `sources`; the project
ledger by three engine events (`Labelled`, `RouterPinSet`, and a `VerdictRecorded` that carries a pin
and what it covers); the snapshot document by the router pin and the labels. No change to a worker's
tools, the jail or the session wire.

**The problem.** `auto` was refused for every rule because nothing could produce the passing verdict
the design asks for. A verdict has to say what it measured, hold only while that stays true, and not
claim more than the measurement can.

**What was considered.** Judging the router with the simulator was rejected: a simulated session's
model is its script, so the decision under test would be the script's own (see the conformance case
`a_router_shaped_script_converges_but_the_decision_is_the_scripts_test`). Building a tape from the
event log was rejected: retention deletes events below a snapshot, and the state already keeps a
thread's entries newest first and never rewrites one, so the state gives the thread as it stood.
Passing on "the instrument did not say Harmed" was rejected, with the numbers below.

**Decision.** A person labels recorded triggers of a rule `accept` or `reject` (`projects.label`), at
least thirty (`judge.needed_labels`). The label is a ledger event, only the owner reaches it, and
retention never drops a labelled trigger. `projects.verdict` builds the rule's tape (`project/tape`):
each trigger, the thread as it stood at that trigger, the relation the gate saw, and what the router
answered. It then measures with `evalstat`. A trigger is a task, a trial passes when the decision
matches the label, and the recorded arm is what the project did at the time.

There are two lanes, and they claim different things. The replay lane runs each labelled trigger
through the gate as the code stands, with the router's recorded answer served back. It is
deterministic and free, and it says the same inputs give these decisions; it says nothing about the
router's prompt or model. The live lane asks a router three times per trigger and says how that router
judged these triggers.

*The scratch judgement session.* The live lane does not use the router's own session, whose `route` tool
applies decisions to the ledger and whose conversation would let one trial see the ones before it. Each
trial opens a session of its own in memory (`client/project_judge_session`, through `harness`) with the
router's pack and the router's resolved model (`serve.routed_identity`: the head of the `router` role,
else `subagent`, else `main`), and one tool: `route`, with the router's name, schema and wording, whose
executor records the items the model gave and applies nothing (`tools/project.judge_tools`). There is no
`project_read`, `reply`, `bash`, `code_mode`, extension or peer tool, and the tool context refuses every
jailed execution. A successful `route` call ends the run. The trigger's text arrives under the router's
own `TriggerOrigin`, so provider projection fences it with a marker longer than any run of `=` in the
text, and the thread as the tape holds it (ids and whether each was received, oldest first, nothing
later) comes first as host text. Any action but `ignore` for the candidate counts as taking it on, as the
tape records it; a run that routes nothing for the candidate counts as declining and is counted in the
report as unrouted. The session retries a failed request three times and not without limit, so a
rejected key fails the run instead of holding it to the wall limit.

*The run is bounded and does not block the project actor.* `projects.verdict` with `lane: live` starts
the run in a weft task and answers at once with `state: running`. Four trials run at a time
(`project_judge.default_concurrency`) and the whole run has twenty minutes
(`project_judge.default_wall_ms`). The first trial that fails ends the run, since a verdict over a
partial set of trials is not a verdict and further calls would be spend with nothing to buy. The task
reports each trial's spend to the actor as it ends, and the actor holds the run in memory: the board's
`run` object for the rule shows `done`, `of`, `calls` and `tokens` while it goes and how it ended after
(`passed`, `failed`, `incomplete`) with the same spend. A second run on a rule whose run is going is
refused in words. A run that fails, is cut off, or finds the router pin changed when it ends (a verdict
recorded under the new pin would claim the new model) records nothing. The run is never resumed: a
restart ends it with the actor and the restarted actor has none.

*Every scratch session stops.* A trial closes its session when the model has answered or failed. A trial
cancelled from outside, by the wall limit or by a failed sibling, is killed and cannot close what it
opened, and a session left to die with it would keep restarting a writer whose store is gone. Each
session is therefore opened and held by a custodian process, which the run adopts as the trial's owner
(a weft managed task): the run asks it to close when it cancels the trial and holds the trial's slot
until it has ended. The custodian also closes the session when the trial's process goes down for any
reason, which is what the project actor stopping does. The tests check each path: success, failure,
the wall limit and the actor killed while trials are in flight.

A pass needs three things: the instrument's verdict is neither `Harmed` nor `Incomplete`, the
instrument's interval of the change in agreement stays above a thirty-point drop
(`judge.max_bound_points`), and the candidate's own agreement with the labels reaches 75 percent of
its trials (`judge.min_agreement_points`). The second is needed because the recorded arm is one
decision per trigger and not three trials. On the synthetic plans in
`project/test/project/verdict_test.gleam` (300 plans of thirty triggers, three live trials) the verdict
reads `Harmed` on 60 percent of thirty-point drops and 18 percent of fifteen-point drops, against the
instrument's own 95 and 40 percent with three trials on both arms. Passing on "not `Harmed`" would let
about a third of thirty-point drops through. With the interval rule, 4 percent of thirty-point drops
pass, 36 percent of fifteen-point drops pass, and 87 percent of runs with no change pass. A pass rules
out a large regression and does not show parity, and the verdict records how far down its interval
reached (`bound_points`).

*The absolute floor.* Both of those compare the candidate with the recorded arm, so neither says the
candidate is any good. A router that disagrees with the person on half the triggers, and did so when it
was recorded, shows no change on either arm and passed the interval rule on 249 of 300 synthetic plans.
The third requirement is the absolute claim, at most one trial in four against the person's label. The
value, 75, follows from the size of a run. A guess agrees on half the trials. A router that answers the
same way every time clusters its three trials, so thirty triggers give an observed agreement a standard
error near 9 points, and 75 is 2.7 of them above guessing. A router that is right 85 percent of the time
passes about nine runs in ten, and one that is right 75 percent of the time passes half of them. A lower
floor would admit routers the person's labels say are wrong on more than one inbound message in four,
and `auto` acts on those messages without asking. The figure is rounded down, so a run on the line is
not counted in. Re-run on the same plans (`verdict_test.gleam`), with a router that agrees on 45 to 55
percent of triggers on both arms, the interval rule alone passes 249 of 300 plans and the floor passes
none; at 60 to 70 percent the floor passes 2; at 80 to 90 percent it passes 264. For routers that agree
on 75 to 100 percent with no change, 280 of 300 pass. For a fifteen-point drop from a router that agrees
on 80 to 100 percent, the interval rule passes 124 of 300 plans and the floor 68. The interval rule's own
figures above do not move, because the floor can only remove passes. The floor applies to the replay
lane as well, since `outcome_of` is shared: a replay of a router whose recorded decisions agree with the
labels on under 75 percent of the trials fails, which is the signal that the pair should not be in `auto`.

The floor as first written took one share over all the trials, and that cannot see a router that
declines everything when most labels are rejects: such a router agrees as often as they are rejects, so
a person who labels thirty triggers of which two are accepts had a floor that a router that never accepts
passed at 93 percent. The floor is now taken per label class, among the triggers labelled accept and among
those labelled reject, and the lower of the two is `agreement_points`. The router that declines everything
reads 0. The plan figures above are measured that way, with half the labels of each kind, and they are
lower than the overall share gave (the figures that were 283, 278 and 96 above) because the lower of two
noisier shares is lower still. A label set with no accept, or no reject, cannot pass, so `judge.judge`
refuses it (`MissingLabelClass`) and the live lane refuses it before it spends a call, in words that
name the missing kind. A second-pass figure the old text gave, a router right 75 percent of the time
passing about half of runs, was a guess and not a measurement; on these plans it is 82 of 300.

A verdict is pinned to the policy version, a digest of the router's pack, and the router's profile and
model key. `RouterPinSet` announces the last two at each start and writes nothing when they are
unchanged. Changing any of the three makes every verdict measured under the old pin stale, and the
engine returns the pairs that relied on it to `observe` in the same event, so the demotion is in the
ledger and survives a restart. `auto` is refused without a current passing verdict for that source and
rule, in words that say which of the three changed and how many labels are missing. A rule configured
as `auto` starts in `observe` unless a current verdict already exists. Explicit work never reads any of
this.

Only a live pass unlocks `auto` (`state.verdict_of`). A replay pass reads `replay_only` and unlocks
nothing, because replay serves the router's recorded answers back: an unchanged gate agrees with its own
recording whatever the labels say, so a replay pass would admit a router that was never judged. The
daemon runs the live lane, so a rule reaches `auto` through a live pass, and only through one.

**What it costs.** The model in the pin is the registration's profile and model key, because the
model a `[roles]` chain resolves to is chosen when the session opens and is not visible to the
project. A change to that chain alone does not move the pin. The prompt revision is the router's
pack, not its tool descriptions. Thirty labels is a person's effort per rule, and a rule with fewer
cannot run on its own. The replay lane re-runs the gate and serves recorded router answers and
overload outcomes, so a change to the queue limits or the attention limit is not judged by it. A
tape's relation is derived from the state's subscriptions, which are not timestamped, so it is the
state's record of what the gate read and not the gate's own stored input.

The live lane measures the router's model on a reduced context. The scratch session has `route` and not
`project_read`, so it cannot open a ticket's card or another message of a thread before it decides, which
the router can; the pack still names `project_read` and `reply`, and a call to either is refused as an
unknown tool and the model is free to try `route` again. The system prompt is the router's pack rendered
for one tool and carries none of the operator's instruction files, which the router's own prompt may. A
live pass says how the model judged these triggers with what the scratch session shows it, and a router
that leans on `project_read` to decide is measured without it. The run costs ninety model calls for thirty
triggers, a daemon restart loses a run in progress and its spend, and the spend of a trial killed
mid-request is not counted. The twenty-minute wall limit and the four trials in flight are constants and
not configuration.

## Addendum: review fixes (2026-11-02)

**Affects**: one new `ReviewReason`, `InferredWork`, written as `{"k":"inferred_work"}` in a
`ReviewRequested` event and in the snapshot's ticket facts, and a board `review` sentence for it. An
older ledger never holds it, and a reader that predates it fails the decode of a line that does.
No command, wire field or `loom.toml` key changes.

**Inferred work is published by a person.** `NetworkOff` on an inferred worker does not stop it from
writing what its sandbox reads into a commit, and the host publishes a passing commit with the owner's
credentials. Considered: scanning the diff for secrets, which is open-ended; and a host check on
the Mandate in `start_publish`, which leaves an engine that asks for a publish it will not get. Decided:
`work.check_passed` on an inferred Mandate sets the review reason and emits no `PublishBranch`, so the
host cannot publish it by any path. `PersonPublished` still does, with readiness `Published`.
What it costs is a person's click on every inferred ticket that would otherwise have opened a
pull request by itself.

**Inferred text does not steer an explicit ticket.** `intake.takes` gave an inferred comment on a
followed thread to any open ticket when the comment's rule pair was in `auto`, whatever the ticket's
own Mandate. A stranger's matching comment could then steer a worker that holds the owner's network,
and the host publishes that worker's commit after a pass, which is the case the inferred worker's jail
and the person-publishes rule exist to stop. Considered: marking the ticket inferred once such text
reaches it, which changes a Mandate after it is written and breaks its immutability; and keeping the
delivery but withholding publication, which still lets the text drive a worker with the owner's
network. Decided: an inferred trigger reaches a ticket only when that ticket's Mandate is inferred.
`intake.takes` refuses it for an explicit ticket in every mode and the trigger goes to the router.
`route.route` refuses `attach` and `resume` of an inferred trigger onto an explicit ticket with a new
`Refusal`, `InferredOntoExplicit(trigger, ticket)`, which changes nothing, while `accept` still opens
an inferred ticket. `work.retry` keeps the same rule when it rebuilds the inbox from the origin
thread. No wire field, command or `loom.toml` key changes, and the refusal is a sentence on the
router's result. What it costs: a CI failure on an explicit ticket's pull request is inferred, so under
`auto` it no longer reaches that ticket's worker and becomes a candidate for a new inferred ticket,
which a person must publish; and a follow-up that only a bot or a non-addressing person wrote no
longer reaches the worker it was about. A person who wants the worker to act on such text addresses the
agent on the thread, which is an explicit trigger.


## Addendum: the template (2026-11-02)

**Affects**: one new `[project]` key, `setup`, and a new row on a project's board; one new host ledger
record pair, `template_built` and `template_failed`, and one new effect-row kind, `template`, which a
reader that predates them settles as an unknown job and reads as no template. `projects.retry` accepts
the ticket name `setup`. The check's `PATH` is the daemon's own. No engine event, no frozen interface
and no wire field changes.

**The problem.** Measured on a real Loom task, a check ran in a fresh clone with a fixed `PATH`, `HOME`
set to a directory in the tree, and the network off. `go` was not found, the system `python3` was too old,
and neither hex packages, Go modules nor Git dependencies could be fetched. The check has to stay offline,
because it runs code a worker wrote. A worker's clone was also a 228 MiB `git clone --no-hardlinks` each.

**What was considered.** Turning the network on for the check: rejected, because a worker's code would
then run with the network on and with the repository's own secrets in reach. A shared dependency cache
outside the trees that every check mounts read-only: rejected, because the cache has to be filled by
something with the network on, which is the same step, and a mount of the host's cache into a jail widens
what the jail reads. Fetching in the clone before the worker starts: rejected, because it runs the
repository's scripts in a tree the worker is about to write. Decided: a template.

**The decision.** `setup`, an optional command of at most 4096 bytes, is run once per base commit by the
host, on a clean checkout of the recorded base that the host cut from `host.git`, in the check's jail with
the network on. The jail is the check's with two differences: the network is on and the CPU, wall and file-size
limits are lifted (the caller's timeout is the wall), with memory raised to 8 GiB and processes to 4096.
Its only writable root is the tree, `HOME` is `<tree>/.loom-check-home`, `TMPDIR` is `$HOME/tmp` (the jail
leaves no other place to write, so a toolchain's work directory goes there), the state-root
and credential masks apply as for a check, and the environment carries only the daemon's `PATH` and the
check's fixed variables. Then `check` runs once on the same tree with the network off, to show it passes on
the clean base. Only then is the tree renamed to `<state>/projects/<id>/template`. It is a normal
non-bare repository holding no linked worktree, alternates file or link under `.git`, and its
`.git/config` holds only what `git init` writes, because it was made by fetching one commit from
`host.git` by path: no remote, no URL, no credential helper. It is masked from sessions and checks as
`host.git` is.

Each worker clone and each check tree is `git-cow copy <template> <dest>`, or `cp -RPp` when no
`git-cow` is found or it fails for any reason but refusing the template, moved to its commit by a fetch
from `host.git` and a checkout that keeps ignored files. Exit 2 from `git-cow` is a refusal of the
template and is an error. The copy runs in the sandbox, writable only in the destination's parent. A
copy of a template carries no credential, and nothing a worker writes reaches the template, `host.git` or
the owner's `.git`. Files the build left untracked are listed in the template's `.git/info/exclude`, so
a clone reads clean.

The daemon's own `PATH`, read once when the machine is read, is what `setup` and `check` see. The system
directories are the fallback when it has none. A project's worker jails do not share it.

The lifecycle is a pure state in the project actor: preparing, ready at a commit, failed, or base check red.
A build is one durable `template` row run in a weft task, its two outcomes are host records, and replay
rebuilds the state. A new assignment waits, its attempts untouched, until the template is ready, so
tickets queue and nothing fails. If `setup` or the base check fails, no worker starts and the board's
sources list carries a row for the setup that says it is the project's setup and not any ticket, with the
last 4000 characters of the output. The base is looked at every ten minutes and rebuilt only if it
moved, in a new directory swapped in on success, so a failed rebuild keeps the last good template and shows a
note. A build interrupted by a crash is cleaned up and redone, and a swap that stopped between its two
renames is undone before anything else.

**What it costs.** A dependency change in a worker's commit is not fetched: the offline check fails,
and a person decides. `setup` runs the repository's own scripts with the network on, jailed: it can
read what the host reads minus the masks, write only the template, and reach any host on the network, so
reading `setup` is reading the build file of a repository about to be run. A rebuild uses CPU and disk, up
to one per ten minutes. A copy that is reading the old template while a rebuild swaps it can fail, and the
ticket tries again. Build output that is not ignored by the repository is excluded from the clone's
`git status`, so a worker's file at one of those paths is invisible to the host's clean test. The template
is a second copy of the build on disk, and the copies are cheap only where `git-cow` can clone.
