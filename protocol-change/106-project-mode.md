# protocol-change/106: projects, tickets and the trigger origin

**Status**: PROPOSED 2026-11-01. The owner accepted the design's five decisions
([docs/design-notes/project-mode.md](../docs/design-notes/project-mode.md)); this
proposal's formats aren't yet accepted, and nothing is built.
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
judged these triggers. The lane's arithmetic is built (`judge.live_samples`); the daemon has no scratch
router session that answers without feeding the project's own engine, so `projects.verdict` refuses
`live` in words, and a test supplies a scripted decision to show it works. Building that session is
what remains.

A pass needs two things: the instrument's verdict is neither `Harmed` nor `Incomplete`, and the
instrument's interval of the change in agreement stays above a thirty-point drop
(`judge.max_bound_points`). The second is needed because the recorded arm is one decision per trigger
and not three trials. On the synthetic plans in `project/test/project/verdict_test.gleam` (300 plans
of thirty triggers, three live trials) the verdict reads `Harmed` on 60 percent of thirty-point drops
and 18 percent of fifteen-point drops, against the instrument's own 95 and 40 percent with three
trials on both arms. Passing on "not `Harmed`" would let about a third of thirty-point drops through.
With the interval rule, 4 percent of thirty-point drops pass, 36 percent of fifteen-point drops pass,
and 87 percent of runs with no change pass. A pass rules out a large regression and does not show
parity, and the verdict records how far down its interval reached (`bound_points`).

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
recording whatever the labels say, so a replay pass would admit a router that was never judged. Since
the daemon can't run the live lane yet, no rule can reach `auto` in this version.

**What it costs.** The model in the pin is the registration's profile and model key, because the
model a `[roles]` chain resolves to is chosen when the session opens and is not visible to the
project. A change to that chain alone does not move the pin. The prompt revision is the router's
pack, not its tool descriptions. Thirty labels is a person's effort per rule, and a rule with fewer
cannot run on its own. The replay lane re-runs the gate and serves recorded router answers and
overload outcomes, so a change to the queue limits or the attention limit is not judged by it. A
tape's relation is derived from the state's subscriptions, which are not timestamped, so it is the
state's record of what the gate read and not the gate's own stored input.
