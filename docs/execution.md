# Execution

How work actually gets done in this repository when an agent is driving it:
how a wave is planned, how sub-agents are briefed and monitored, how their
output is verified before it lands, and the failure modes that have already
cost real time here.

This is not a style guide (`docs/gleam-style.md`) or a plan
(`docs/issue-plan.md`). It is the operational layer between them. Everything
below is written from waves that ran, and every rule earned its place by
something going wrong first.

---

## 1. The shape: one orchestrator, disjoint slices

The pattern that works is a root orchestrator that plans, dispatches,
verifies and commits — and sub-agents that each own **one slice on a
disjoint file set**, doing no git operations at all.

A wave is three or four slices dispatched at once. The slices are chosen so
their file sets do not overlap, because sub-agents share one working tree.
Two agents in one package is survivable if they touch different files; two
agents in one *file* is not.

The orchestrator's job is the part that cannot be delegated:

- deciding what the slices are and why they are disjoint,
- writing briefs dense enough that the agent does not have to guess,
- **verifying the work independently** rather than believing the report,
- staging and committing atomically, in the repo's own commit style,
- and holding the cross-slice picture nobody else has.

The orchestrator should not also be implementing a slice. It will be
interrupted by notifications, and half-finished edits in the shared tree are
exactly what breaks the other agents.

### What to delegate, and what never to

Delegate: an implementation slice with a clear boundary; a broad read-only
survey where you want the conclusion, not the file dumps; a design ruling on
a contested decision; mechanical metadata work over many items.

Never delegate: the decision about what the slices *are*; the final
verification; the commit messages; anything requiring the whole-tree picture.
An agent that only sees `packages/broker` will write a commit message that is
true about the broker and wrong about the change.

---

## 2. Briefing

A brief that produces good work is long. Cheapness in the brief is paid back
with interest in wrong work. Every brief should carry:

**The required reading, in order.** `CLAUDE.md`, then the specific package
docs, then the specific files with line numbers. Do not make the agent
discover the map; it will spend a third of its budget doing so and still miss
`docs/gleam-style.md` Part IV.

**The issue, restated with evidence, not just its number.** Fetch the issue
and quote the load-bearing part, with `file.gleam:line` citations you have
checked yourself. Agents will believe an issue's framing; issues in this repo
have repeatedly been wrong in their diagnosis (see §6).

**The ownership list and the no-touch list.** Name the files this slice owns
and the files other agents are live in. Without this an agent will
helpfully fix something outside its slice and produce a merge problem.

**The cut list.** Say explicitly what *not* to build. This is the single
highest-value paragraph in a brief. Agents over-deliver by default: they will
add a config knob, a second mechanism, a metric. Naming the five things you
do not want is what keeps a fix small.

**The standard of proof.** In this repo that means: mutation testing (§4), a
green `make check-<package>`, `gleam format --check`, and the relevant gate
(`make lint`, `make doc-check`, `make prelude-check`).

**The house rules that are not in the code.** Commit authorship, the commit
message format, no AI-tool names in any repository artifact, generated files
get their own commit, and — a real incident — **never run `git checkout
<file>`**, which destroyed another agent's uncommitted work once here.

### Give the ruling, not the question

If a design decision has already been made — by you or by an advisor — put
the decision *and its reasoning* in the brief. An agent handed an open
question will re-derive it, usually differently, and you will discover the
divergence at commit time. Handing over "keep the ledger keyed on the pair;
here is why; write the addendum inside the ADR" produces the right code.
Handing over "decide how to key the ledger" produces a week of drift.

---

## 3. Monitoring

Sub-agents run in the background and notify on completion. Between dispatch
and that notification:

- **Do not poll the agent's transcript file.** It is full JSONL and reading it
  will flood your own context.
- **Do useful, non-conflicting work**: read-only scoping for the next phase,
  GitHub triage, filing issues. Not edits.
- Watch `git status --porcelain` and `git log --oneline` to see the tree
  moving. That is the cheap, safe progress signal.
- Never claim or predict a running agent's results. You do not know them.

**A completed-agent notification is not proof the work is good.** It is
notice that verification can start.

---

## 4. Verification: the part that is not optional

**Do not trust an agent's report of its own gates.** Reports here have been
sincere and stale, sincere and mis-scoped, and correct — and the three are
indistinguishable from the text. Re-run the gate yourself on the real tree.

### Capture the exit code of the thing you care about

The trap that caught me twice in one session:

```sh
make check > log 2>&1; echo "EXIT=$?"; tail log     # WRONG
```

Run as a background command, the *reported* status is the last command's —
`tail` — which always succeeds. I twice announced a green tree that had
failed. Either check the recorded `EXIT=` line explicitly, or do not chain:

```sh
make check > log 2>&1; echo "MAKE_EXIT=$?"          # then read MAKE_EXIT
```

Then read the log for `failures`, not just the summary line.

The same trap has a background form, and it caught a third green
announcement: a gate launched as a detached background command finishes
with the *wrapper's* status — the `echo`'s, which is zero — and the
harness's "completed (exit code 0)" notification reports exactly that.
The `MAKE_EXIT=` line is written into the task's output file and means
nothing until somebody reads it. A background gate whose recorded exit
line was never read is a gate that did not run, whatever the
notification said; in the caught case the log's first page was compile
errors.

### Bound test runs and report elapsed time

Use `make test-<package>` or `bash scripts/test.sh <package>`. The full
gate, E2E targets and soak chunks use the same runner. It starts the
package application, prints EUnit test names and timings, and preserves
the existing per-test timeout scale. The compile runs first, under its own
independent process deadline, defaulting to 1,200 seconds; set
`LOOM_BUILD_TIMEOUT_SECONDS` to change it. The test run then gets its own
independent process deadline, also defaulting to 1,200 seconds per package
invocation but no longer covering compilation. Set `LOOM_TEST_TIMEOUT_SECONDS`
to a finite positive value for a measured shorter or longer run. Either
deadline exits 124, never success, and kills its command's process group.
That kill is a test failure, not proof that external effects drained
safely.

For a focused run, use an explicit filter:

```sh
LOOM_TEST_TIMEOUT_SECONDS=60 bash scripts/test.sh storage --match quoted_writer_identity
```

The filter matches module or function names, including test generators.
No matches is an error. Do not pass `--match` to `gleam test`: the pinned
Gleeunit entry point ignores that argument and runs every test.

On macOS the wrapper runs its command under `caffeinate -i`; the idle-sleep
assertion ends with the command and changes no persistent power setting.
Manual sleep can still suspend the host. The wrapper checks both wall and
monotonic elapsed time, so suspension or a backwards wall-clock adjustment
cannot silently extend its budget. When a log has a long quiet interval,
check both test timing and the host's sleep log before calling it a deadlock.
In the September 5 run, two sleep intervals accounted for roughly 73 of
76 wall-clock minutes; the awake rerun passed in 186 seconds.

The watchdog's fault tests run under their own 20-second deadline in
`make check`. They cover a blocked command, descendant termination,
interrupts, invalid deadlines and exit-status preservation. Go tests retain
their own ten-minute timeout and run under the outer process deadline too.

### Keep prerequisite skips visible

EUnit captures a passing test's stdout, even with verbose progress. Emit
prerequisite `SKIP` diagnostics through `io.println_error`, as the native TUI
fixture does. Otherwise the skip census cannot distinguish an executed test
from a skipped one. `scripts/test_skip_reporting.py` checks those emitters and
runs a real passing EUnit fixture through the census: undeclared skips fail,
declared skips pass, and unused declarations fail. A stale-declaration error
does not justify deleting its waiver until the actual prerequisite and output
path have been checked.

Keep the leading `SKIP` literal in the emitting call. The source guard checks
that convention; it does not follow a marker assembled into a variable first.

### A long-lived tree's incremental build cache can lie

A deterministic test failure in a package the diff does not touch is not
automatically a flake, and re-running until it passes is not a
diagnosis. Twice in one session, `storage`'s racing-creates test failed
identically on a tree whose `packages/storage` was untouched: the same
commit was green in a fresh worktree, no stray BEAM processes, no file
locks — a poisoned incremental artifact under `packages/<pkg>/build/dev`
in the long-lived tree. The fix is `rm -rf packages/<pkg>/build/dev`
(and the package's scratch state, e.g. `test_db`), then re-run. Check
the fresh-worktree control *first*: it is what separates "my tree is
poisoned" from "this commit is broken", and both agents who hit it
without the control mis-filed it as a flake.

### Verify on a clean checkout, and mind where you put it

To check a commit independently of other agents' uncommitted edits, use a
git worktree:

```sh
git worktree add /home/user/loom-verify <commit>
```

**Not under `/tmp`.** Code mode refuses a cap socket under `/tmp`, because
the jail replaces it with the scratch tmpfs — correct behaviour that will
present as seven mysterious codemode failures and cost you an hour. `/tmp`
also fails `make codemode-seed` discovery. Put verification worktrees beside
the repo, and remove them when done.

### Mutation testing is the standard of proof

A passing test proves nothing about whether it *would* have caught the bug.
Every fix should be validated by breaking the code under it and observing
the intended test fail — and by observing that *only* the intended tests
fail, which is how you learn a test is over-broad.

This is not ceremony. It has repeatedly produced the actual finding:

- Reverting `exec.checkout` to `process.call` did not fail one test, it took
  the whole suite from 154 passing to 25 passing and 3 failing — because the
  panic propagates through the broker's actor loop. The blast radius *was*
  the property under test.
- The naive prune in the abort-epoch table made a *pre-existing* test fail by
  the waiter never being refused at all, which is how the dangerous direction
  of that bug was found rather than argued.
- A cross-file lint pass added exactly one finding tree-wide and it was a
  false positive — which is what forced the rule's definition to become
  exact instead of broad.

### Run the gates a change affects

`make check-affected` runs the part of the full gate that a change can
affect; `make affected` prints that selection and the reason for each
gate without running anything. Both take `BASE=<rev>` (default
`origin/main`). The change is everything between the merge base of
`BASE` and HEAD, together with the working tree's uncommitted and
untracked files. `scripts/affected.py` makes the selection and
`scripts/check_affected.sh` runs it.

The selection:

- **Static gates, always:** `fmt-check`, `lint`, `doc-check`,
  `prelude-check` and `client-check`. They run over the whole tree and
  take about ten seconds together, so they are not narrowed.
- **Packages:** every package with a changed file, every package that
  depends on one through `[dependencies]` path edges (transitively), and
  every package that names one in `[dev-dependencies]` (one step only,
  since Gleam compiles dev dependencies only for the root package). The
  edges are read from `packages/*/gleam.toml` on every run. A package
  whose tests name a file outside it by a relative path literal, such as
  the real-helper suites' `"/../sandbox/loom-exec"` or codemode's
  `"../../docs/examples/…"`, is selected when that file changes. Each
  package runs through `scripts/check.sh <pkg>`, the body of
  `make check-<pkg>`, in the signoff's lane grouping.
- **Other gates:** a change under `protocol/models/` runs
  `make model-check` (the P models, which need the P tool); a sandbox
  change runs the helper's `--self-test`.
- **The full `make check`,** instead of a package list, for a change to
  `scripts/`, the `Makefile`, `.github/`, the image files, any package's
  `gleam.toml` or `manifest.toml`, the msgpack wire fixtures, or a path
  the script does not classify, and for a change whose affected packages
  are more than half of the Gleam packages (today only `core` reaches
  that).
- **Docs only** (`docs/`, `protocol-change/`, `skills/`, `.claude/`,
  Markdown at the root or at a package's root): the static gates alone,
  unless a test reads the changed file.

For example, a `tui` change selects `tui` and `client` (whose tests take
`tui` as a dev dependency) but not `conformance`, which depends on
`client` without compiling its tests. A `session_view` change selects
`session_view`, `tui`, `web_view`, `client` and `conformance`.

Before the package lanes it builds what their feature-detected suites
need, with the targets the signoff's preparation uses: `binaries`
always, `codemode-seed` when `codemode`, `tools`, `cap` or `client` is
selected, and `server-shipment` when `client` or `tui` is. It sets
`LOOM_BOOTSTRAP_E2E_SERVER` and the fixture provider key as the signoff
does, and after the lanes it runs the skip census over their logs, so a
suite that printed SKIP instead of running fails the run.

The selector also prints `signoff required` or `signoff not-required`.
The owner's rule (2026-09-28): a change may land on `make
check-affected` plus the targeted proofs for the changed code (the
focused tests or drive that show the change does what it claims),
with the Fable review's findings dispositioned. The full signoff
(`make signoff-remote`) is still required when the selector says so:

- when it selected the full check;
- when the change touches the daemon, meaning the packages loomd is
  built from. That set is derived, not listed: `client` (which
  `make server-shipment` exports as loomd) and every package it reaches
  through `[dependencies]`, less `session_view` and `web_view`, which
  the owner's ruling exempts. Today it is `client`, `host`, `core`,
  `storage`, `session`, `machine`, `prompt`, `events`, `runtime`,
  `broker`, `provider`, `tools`, `codemode`, `mcp` and `telemetry`;
- when it touches the sandbox (`packages/sandbox`) or the wire (the
  msgpack fixtures, `session_view`'s `protocol.gleam` and
  `session_wire.gleam`);
- when it changes more than two packages directly.

So a change confined to `tui`, `session_view`, `web_view`, `web_client`,
`lint`, `cap`, `ext`, the P models or the docs can land on
`check-affected`.

`check-affected` does not run what only the signoff runs: the bootstrap
fixtures under shell sabotage (`scripts/e2e_client_bootstrap.sh`), the
simulation soaks, the release and update verification, and the
enforcement expectations. That is why the changes above that reach
those surfaces keep the signoff. The signoff, `make check` and CI are
unchanged by it.

It exits with the status of the first failure (static lane, then the
lanes in listed order, then the skip census) after every lane has
finished; per-lane logs are under `build/affected/`. Check that status
directly, as above.

### Verify the claim, not the vicinity

`make check-<package>` passing does not prove a *performance* fix landed. A
reverted O(n)-for-O(1) fix compiles and passes every unit test; only the lint
rule that measures it noticed. Match the check to the property.

---

## 5. Landing the work

Sub-agents leave work uncommitted; the orchestrator commits. This is
deliberate — the orchestrator has the cross-slice view needed to write an
honest message and to split by concern rather than by agent.

- **Atomic by concern, not by agent.** One slice usually becomes three or
  four commits: the fix, the generated artifact, the tests, the docs.
- **Generated files get their own commit** (`prelude.gleam`, the SQL modules).
  This is repo policy and it keeps a mechanical diff out of a reasoned one.
- **Stage explicitly by path** when another agent is live in the tree. Never
  `git add -A` during a wave.
- **Scan every diff before committing** for AI-tool names — the owner's rule
  is absolute, and `CLAUDE.md` as a *filename* is the only legitimate hit.
- **Check the `AGENTS.md` mirrors** with `cmp`; they are byte-identical copies
  and `make doc-check` gates on it.
- **Write the message about the why.** Prose, not bullet dumps. The best
  messages in this history explain what was believed, what measurement
  changed it, and what was therefore *not* built.

### Sign off locally instead of waiting on the hosted gate

The `main` ruleset requires a `signoff/linux` commit status, posted by
`gh signoff`, and the hosted workflow keeps running as the record. The
status attests that a named person ran the gate, nothing more, so it is
only ever posted by `scripts/signoff.sh`: every CI command as parallel
lanes on one checkout, a verdict, and then the status. Never type
`gh signoff` by hand; treat that the way you would treat a forced push.

`make signoff` runs this platform's lane here. `LOOM_SIGNOFF_HOST=<ssh
alias> make signoff-remote` runs the same gate for HEAD on a Linux box,
through that box's signoff gate (below), and the host is named only in that
variable and your ssh config, never in the tree. Push first: the box
fetches by SHA and `gh signoff` refuses a commit no remote holds. Add
`SIGNOFF_ARGS=--dry-run` to run the lanes and post nothing. Per-lane
logs land under `build/signoff/`; the lane table at the end says which
to read.

The conformance lane also runs `make soak-daemon-sim`, the daemon
simulation's soak, for `SIGNOFF_DAEMON_SOAK_SECONDS` seconds (default 60);
it is budgeted in wall clock rather than in seeds because a daemon seed's
cost varies with the file system and with what its schedule drew.

`SIGNOFF_PARALLEL=<N>` exports `LOOM_TEST_PARALLEL` to every lane, so
each package runs up to N of its tests at once on one emulator; the
modules that touch a VM-global resource are held back and run alone,
declared with a reason in `scripts/serial-tests`. It defaults to 8, the
setting every package passed three runs of three at on a 32-core box;
`SIGNOFF_PARALLEL=1` reproduces the sequential run when a failure has
to be told apart from a concurrency effect.

`LOOM_SIGNOFF_HOST=<ssh alias> make signoff-remote` runs the same gate
inside a fresh container on the remote box, and only there; there is
no bare-checkout mode. The container clones its working tree from a
read-only mount of the checkout the script owns, on its own filesystem,
so `docker run --rm` removes everything a run built. Two hazards shaped
that. The first: the checkout persists between runs by design, so anything a
run leaves behind — a shipment directory, a stale `build/` tree — is
inherited by the next one, which is exactly what happened on PR #378
(2026-09-13): the first `make signoff-remote` found
`packages/tui/build/erlang-shipment` from an earlier run still there and
refused to overwrite it, going red in prep before a single lane started.
The second: the container runs as root, and when its trees were cloned on
the host and bind mounted in, the login account could not delete what
root had built there; by 2026-10-04, 289 of them (214 GB) had filled the
box's disk and a signoff failed at checkout with "No space left on
device". Only three things outlive a run: a per-commit logs directory on
the host, and the Hex/gleam package cache and the Go module cache, both
named Docker volumes chosen because a cold dependency resolution on every
run trips Hex's rate limit (issue #248) within minutes. `scripts/signoff/Dockerfile`
carries the toolchain — the same versions `.github/workflows/ci.yml`
pins, including the patched Gleam compiler CI builds — and
`scripts/signoff_remote.sh`'s own comment has the container flags this
needed and why, along with what was tried and turned out not to be
necessary. The container runs `signoff.sh --dry-run` and posts the
verdict itself afterward from the host's own `gh`, which is the
arrangement that keeps a GitHub token out of the image.

A key handed to agents should not be able to run whatever it sends, and
the driver protocol is exactly that: `scripts/signoff/driver.sh` is
streamed to `bash -s`. So `make signoff-remote` by default sends only
`signoff <sha> [--dry-run] [--parallel N]`, to a host whose key is
pinned in `authorized_keys` to `scripts/signoff/gate.sh`, and
`LOOM_SIGNOFF_UNGATED=1` sends the branch's driver to an ordinary login
instead, which is how a change to the driver itself is tried. The gate
reads the request as data, refuses a commit on none of origin's branches,
and runs an installed copy of the same driver as root through one sudo
rule, from a root-owned state directory holding the checkout and a token
that may write commit statuses and nothing else; the key's account holds
nothing and is not in the docker group. Optional `LOOM_CPUS` and
`LOOM_MEMORY` ceilings keep a gated run from crowding out whatever else
the box does. Each ceiling is applied to two sibling cgroups, the
container's and the base that `loom-exec` uses inside it, so a run can
use up to twice the value set; halve it to bound a run at a given size.
A run belongs to the session that asked for it: a Ctrl-C on the client
cancels the container within thirty seconds and posts nothing, gated or
not. A red run prints the end of each failing lane's log, and `ssh <host>
logs <sha> [lane]` reads a gated run's logs later, since the key that
asked for it cannot read the box's files. The gate's header has the
installation, and what it does
not bound: the commit under test still runs as root in a container that
is not a sandbox, so the commit, not the key, is the trust boundary.

### Landing a `gh stack`, and a busy `main`

`gh stack merge` merges a stack atomically, but it requires
`signoff/linux` on the head of every layer, and only the top layer is ever
signed off: a signoff runs the whole gate on one checkout, and the top
checkout contains the layers beneath it. So a stack lands through a queue
pull request instead. Make a branch whose head is the signed-off top of
the stack (it must sit directly on the current `main`), open a pull
request from it, and merge that. The bottom layer's pull request then
shows as merged, and every other layer's is closed by hand with a comment
linking to the queue pull request. #760 landed the sixteen-layer terminal
revamp (stack #718) this way, on one `signoff/linux` of 1410 seconds.
Write the layer list into the queue pull request's body, because the
closed pull requests are what a later reader finds first.

When `main` moves after a green signoff, the owner's ruling of
2026-10-04 is that a conflict-free update needs only a narrow re-gate:
update the branch, run `make check-affected BASE=origin/main` and
`make doc-check`, and merge. A full second signoff is for an update that
conflicts. On a busy `main` this is what keeps a merge from chasing the
branch it is waiting on, and a flake that appears in the narrow run is
rerun and given its own fix pull request, not waited on.

### Watch for the push race

An agent can commit between your verification and your push. `git push` sends
everything on the branch, not the commit you checked. Diff what actually went
out (`git log --oneline <old>..origin/main`) and verify anything that rode
along.

---

## 6. The recurring lesson: measure before you build

The highest-value output of several slices was **not building the thing the
issue asked for**, because measuring first showed the issue was wrong. This
has happened often enough to be the house style rather than a happy accident.

- An issue proposed a retention window for a growing table. Measurement:
  pruning is unsafe in *both* directions and the dangerous one is silent;
  the growth law was one entry per operation *ever aborted*, not per abort,
  so the filing over-counted by the number of runs per strand; ~110 bytes an
  entry in a process that dies with the session. Shipped: a documented bound
  and a test. Not a config knob whose too-short value is a silent hole.
- An issue diagnosed a release as missing the emulator. Measurement: the
  emulator shipped all along; OTP's start script prepends the release's own
  `bin` to `PATH`. The real cause was two missing files. The fix was smaller
  and elsewhere.
- A sweep flattened a file by an indentation census and added two thousand
  lines, because a wide call formats as one argument per line and the census
  read that as depth. The metric had no sign check. Undoing it removed a
  thousand lines and changed no test.

So: **quantify before mechanising, and prefer a documented bound with a test
over a knob.** When an issue's diagnosis and the code disagree, the code is
right and the issue gets a comment saying so.

Corollary: when you correct an issue, write the correction *on the issue*.
The next reader will find the filing before they find the commit.

---

### Profile the server before optimising it

The daemon's per-turn CPU (issue #359) was diagnosed wrong by reading the
code and right by measuring it: the suspected estimator cost 0.01 ms of a
1015 ms step, and the cost was a JSON codec working one codepoint at a
time plus a branch decoded three times per step. The tools are in the
tree and in OTP; use them before proposing a fix.

1. **Copy a real session store**, never a live one: `cp
   ~/.loom/sessions/<id>.db* <scratch>/`, then `sqlite3 <copy>
   "delete from writer_lease;"` because the session layer takes a writer
   lease on open. `make bench-server DB=<copy>` times the per-step paths
   (scan and decode, projection, the threshold estimate, both request
   encodes, a first step and a cached step) over that branch.
2. **Attribute with `tprof`.** An escript that adds every
   `packages/client/build/dev/erlang/*/ebin` to the code path can call
   `client_dev:open/1` and `client_dev:step/1` directly. `tprof:profile(fun
   () -> client_dev:step(Rig) end, #{type => call_time})` names the
   functions in the calling process; for work done in other processes (the
   storage actor decodes the scan) use `tprof:start`, `tprof:enable_trace
   (all)`, `tprof:set_pattern('_','_','_')`, run the step, then
   `tprof:collect` and `tprof:inspect(Sample, total, measurement)`. The
   `call_memory` type says who allocates.
3. **Split the scheduler's time with `msacc`**: `msacc:start()`, run a few
   steps, `msacc:stop()`, `msacc:print(msacc:stats(), #{system => true})`
   gives emulator versus gc versus sleep per thread, which is the number
   the issue's native sample could only guess at.
4. **Fix the shape, then rerun the bench** and put both numbers in the
   commit. A change that does not move the bench did not fix the cost.

## 7. Advisors

### Protocol changes during the single-daemon work

The owner delegated protocol acceptance on September 5, 2026. Keep the
numbered proposal before implementation. Use primary review for a small,
local addition and independent adversarial critique when the change carries
meaningful cross-layer or concurrency risk. Verify findings against the code
and accept the proposal with the necessary corrections. Record the review and disposition in the
proposal so the owner can follow the decision afterward. A protocol change
within the approved work does not need another owner approval round.

This delegation does not authorize unrelated scope changes, new product
features or external coordination beyond the requested work.

For a contested or security-sensitive design decision, dispatch a
**read-only advisor** before any code is written. Give it the required
reading, the real constraints, and a numbered list of questions — and demand
a decision with its cost, not a survey. Ask explicitly for the **cut list**
and for the **cheapest thing that would prove the ruling wrong**.

Tell an advisor it may reject the framing. The most valuable advisory output
in this repo began by correcting the premise of the question: the claim that
`clear_call` was the only door that had ever checked a capability was false —
the harness's own filesystem tools had never passed through the broker — and
the mechanism the question assumed had to be built already existed and was in
production. Both corrections made the work smaller.

An advisor must be told, in the brief, that other agents are live in the
tree and that it must not write anything.

---

## 8. Hazards specific to this repository

- **`git checkout <file>` has destroyed uncommitted work here.** Never use it
  to clean up during a wave. Say so in every brief.
- **Verification worktrees under `/tmp` break code mode** (see §4).
- **A daemon a test launches reads the operator's home.** `loomd` loads
  `~/.claude/settings.json` hooks, home skills, `~/.loom/extensions`, home
  guidance files and the global Git identity from `HOME`. The shipped
  fixtures once inherited the developer's `HOME`, so their sessions ran the
  developer's Claude Code hooks and went red on macOS while
  `signoff/linux`, whose container has no `~/.claude`, stayed green. They
  now launch the daemon through `test/support/shipped_server`, which gives
  it an empty private home and a generated Git identity, so they need no
  special `HOME` from whoever runs them. Anything new that launches
  `bin/loomd` from a test needs the same isolation.
- **Two generated artifacts go stale from one change.** Touching
  `packages/cap`'s public surface stales both `tools/prelude.gleam`
  (`make gen-prelude`) and the code-mode build seed (`make codemode-seed`),
  which verifies its `gleam.toml` is *byte-identical* to the table the
  compile service generates. `make check` catches the first; only an
  end-to-end run catches the second.
- **`process.call` panics on timeout and on a dead callee.** Inside an actor's
  message handler that is not an error return, it is the actor's death. Use
  `broker/internal/call.try_call` where a caller holds a verdict its death
  would lose.
- **Eager arguments.** `bool.guard`'s `return:` and every `unwrap` fallback
  are ordinary arguments evaluated on every call. Use the `lazy_*` forms for
  anything that recurses or allocates.
- **The lint warnings are the backlog.** `make lint` exits 0 with hundreds of
  warnings by design; four rules gate. Read them — they are the argument for
  promoting the next rule, and they are only useful if somebody looks.
- **A Gleam module's compile time can go exponential in the Erlang
  inliner, and the symptom is a CI deadline, not a build error.** Gleam
  compiles every module with `inline`. The inliner attempts each local
  call and, when it abandons an attempt for effort, restores the state it
  began from, including its cache of visited expressions (an attempt
  abandoned for size keeps its state, which is why a larger
  `inline_effort` makes the same module compile in seconds). A function
  that computes an expensive expression and then applies N local steps to
  it re-visits that expression about 2^N times. `packages/tui`'s `update` hit
  this at N = 6: the tui package took 75 s to compile on a laptop and 200 s
  on a CI runner, which pushed the shipped-multiplayer and bootstrap
  fixtures past their 180 s deadlines in three lanes at once, each looking
  like a hung test. Diagnose with `erlc +time` on the generated
  `build/dev/erlang/<pkg>/_gleam_artefacts/<module>.erl` (add `-I` for the
  package's `include` and `-pa` for each `build/dev/erlang/*/ebin`); if
  `core_inline_module` is the whole time, ablate the suspect function's
  stages and expect a halving per stage. The fix is structural, not a
  flag: move the steps into a function that takes the expensive value as
  a parameter (`tui.update` now hands its dispatched model to
  `settle_update`, and the package compiles in 6 s). Making the callee
  `pub`, flattening nested calls into pipes, or hiding the expensive
  expression behind a local call while the steps stay in the caller does
  nothing, and the last of those measures worse; only the parameter shape
  or a cross-module call changes the count. The September 21 notes read exposed
  the same shape inside `update_tick`: the read-service chain was still applied
  to the expensive drain expression. Passing that result into `settle_tick`
  reduced `core_inline_module` from 51.445 s to 1.632 s in generated Erlang;
  the actual Gleam rebuild took 7.80 s and all 654 TUI tests passed. Preserve
  both the original model and drained model as parameters so quiet-time
  accounting keeps the same before/after comparison. Issue #374 then split
  the client into modules: `settle_update` stays in
  `packages/tui/src/tui.gleam`, `update_tick` and `settle_tick` are in
  `packages/tui/src/tui/tick.gleam`, and most steps on both chains are now
  cross-module calls, which the inliner never attempts. A rebuild after a
  change to `tui.gleam` fell from 9.6–9.8 s to 1.4–1.7 s. The boundaries stay
  for the local steps that remain.
- **A Loom session that runs the gates is already inside a jail, and some
  suites can never pass there.** macOS refuses a second `sandbox_apply`
  (`Operation not permitted`, exit 71), so a helper spawned from a jailed
  process cannot confine anything: `make selftest`, the real-helper
  broker, tools, conformance and `lsp_e2e` suites, `make e2e`,
  `make e2e-codemode` and `docker-smoke` are out. Three more things fail
  by design: `exec` of a setuid binary such as `/bin/ps` (Seatbelt refuses
  it), ptys through `/dev/ptmx` (Python reports "out of pty devices"), and
  any write outside the workspace, the user temp directories and the
  per-call scratch. Most gates now say so rather than failing: the Gleam
  suites print `SKIP ...: already inside a Loom/Seatbelt jail` (the marker
  is deliberately not in `.github/declared-skips`, since CI is never
  nested), `--self-test` prints `RESULT: NOT RUN` and exits nonzero, and
  `host/endpoint_test` prints `SKIP endpoint identity`. Still failing noisily
  inside a jail: the Go seatbelt tests (`make sandbox-test`, which skip only
  when `sandbox-exec` is missing), the client shipped fixtures' enforcement
  probe (`client/test/support/enforcement.gleam`), and the client tests that
  call `endpoint.observe` directly (`tui_daemon_test`, `daemon_access_test`,
  `daemon_shipped_identity_recovery_test`). One session lost
  about thirty minutes proving these failures were environmental. Do not
  debug them; signoff and CI arbitrate. Inside the jail, `cargo` finds no
  toolchain because `HOME` is the tool home; the recipe is in
  `scripts/toolchain/gleam/README.md`.

---

## 9. A wave, end to end

1. Pick 3–4 slices on disjoint file sets. Write down why they are disjoint.
2. If a slice has an unsettled design question, run a read-only advisor first
   and put its ruling in the brief.
3. Dispatch all slices in one message so they run concurrently.
4. While they run, do read-only work: scope the next phase, triage issues.
5. On each completion, verify independently: re-run the gate, capture the
   real exit code, spot-check the mutation claims, read the diff.
6. Commit atomically by concern. Scan for AI-tool names. Check doc mirrors.
7. Push; diff what actually went out against what you verified.
8. Close the issues with a comment saying what was decided and why —
   especially where the issue's own diagnosis was wrong.
9. Write down what the next session needs (`docs/next.md`).
