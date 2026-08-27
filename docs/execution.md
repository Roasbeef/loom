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

## 7. Advisors

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
