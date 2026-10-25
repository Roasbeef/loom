# ADR-021: The evaluation instrument sits beside governed evolution and never promotes

**Status**: accepted, implemented in waves 1 and 2 · **Date**: 2026-10-25 ·
**Spec ref**: protocol-change/100 · **Issues**: #236, #807, #492 ·
**Design**: [`docs/design-notes/eval-instrument.md`](../design-notes/eval-instrument.md)

## The question

Loom's governed evolution plane could already compare a prompt candidate
with its base, but the comparison could not tell an improvement from
noise. It took one sample per arm. It scored by exact file bytes. Its
verdict failed a candidate if any candidate trial failed and never looked
at the baseline. The owner asked for an evaluation framework deep enough to
test prompt changes, tool descriptions and model variations, and to feed a
later GEPA-style search. That raised five questions:

1. Where does such an instrument live, and how does it relate to the
   governed plane that already approves and selects candidates?
2. What is a task, and how is a benchmark kept honest while an optimizer
   searches against it?
3. How is an agent's work graded when the agent is adversarial towards its
   grader?
4. What decides "better", and what may it claim with thirty tasks?
5. What can be tested without spending on a model?

## Decisions

**Two packages, and the governed plane remains the only route to
promotion.** `packages/evalstat` holds the statistics and the decision rule.
It is pure Gleam on the standard library and is held to the R6 portable set,
because the governed verdict and any future report page must call the same
functions and its properties must run without processes on both targets.
`packages/eval` is the effectful developer tool: tasks, the miner, the
runner, the jailed verifier, the replay lane and exports. Like
`conformance`, it depends on `client` and ships in nothing. The instrument
produces evidence; it never approves or selects. A candidate it favours is
run again through the governed `evolution.compare` on an admitted task set.
That is the cost of not building a second promotion mechanism, which #236's
owner comment forbids.

**One trial recipe, one grade, one decision rule.** `serve.trial_settings`
opens trials for both paths. A trial's scorer returns a `rollout.Grade`
(reward, named scores, bounded side information, the verifier run).
`evalstat` decides for both: the governed `rollout.decide` maps Improved to
Passed, Harmed and Indistinguishable to Failed, and Underpowered and
Incomplete to Inconclusive.

**Tasks are content-addressed, and the plan is the denominator.** A task's
id is the digest of its canonical bytes, so editing a task to make an agent
pass mints a new task instead. A git workspace is named by commit and tree
id and materialised with `git archive`, because a worktree's history would
show the agent the fix. A run's plan materialises every task, arm and trial
index before it starts. A missing row makes a verdict incomplete instead of
shrinking n. An agent timeout is a failure, never a requeue. A cell's
ledger rows are checked in order, so a scored trial cannot be rerolled.

**The raw material is the repository's own history.** The miner turns
commits that fix a module and add its test into tasks. A test that fails
with only the test applied and passes with the fix is fail-to-pass. One
that passes both times is pass-to-pass. A commit whose test never fails is
culled. Before a task enters a set, the prover runs the gold patch and no
patch through the jailed verifier and admits the task only at gold one and
null zero.

**The verifier assumes the agent is adversarial.** The verifier runs after
the agent's session has retired, in a fresh jail, on a copy of the frozen
workspace. The copy holds only regular files and directories. It drops the
agent's `logs/` and `build/` and overlays a dependency build prepared on the
host before the agent ran. Hidden test files and the runner scripts are
written into the copy last, and never through a link. A pass needs exit
status zero, every fail-to-pass and pass-to-pass test observed passing, and
a passing reward map. Code an F2P test reaches still runs in the test VM
and could print forged test lines. The defence is the hidden test bodies
and the pristine build, not output parsing, and the package doc records
the limit.

**The verdict says what the evidence can bear.** The verdict uses a paired
per-task difference with a task-clustered interval, an exact sign test on
task signs, and a direction check. The minimum detectable effect is
reported first, and Underpowered is a verdict with a reason. At the model
door's caps, most honest comparisons are Inconclusive. Protocol-change/100
gives the arithmetic. The door's turn and wall ceilings were raised so a
powered comparison is possible at all. The dollar and token ceilings, which
bound the operator's money, did not move.

**Two lanes make two claims.** The replay lane records provider responses
verbatim. It matches requests by a normalised digest and reports the first
divergence by key path. It proves only that the harness sent the same
requests and the verifier gave the same reward under the same model
outputs, and it needs no key. The live lane makes model and prompt claims
and costs money.

**The holdout is sealed by where ids may be admitted.** Tasks split into
tune, validate and holdout by a hash of their family, and
`split.admissible` refuses a holdout split by name. The seal is complete
when the admission tool that turns tune and validate splits into governed
task sets calls it. That tool and task-set v2 admission are the next slice,
and until it lands no instrument task reaches the model door at all.

## Alternatives rejected

- *Generalise `rollout.evaluate` into the instrument.* Its ceilings are
  right for a model spending the operator's money, and wrong for a
  developer measuring a change. It gained K samples and the shared verdict
  instead.
- *A Python harness, or Harbor as the runner.* Most of the instrument either
  needs Loom's jail or is a decision rule that must be property-tested.
  Harbor is an export target, and its agent adapter waits on `loom run`.
- *A SQLite ledger and coordinator process,* as nanocodex used. A
  pre-materialised plan and an append-only JSONL ledger give the same
  pairing for one operator.
- *Score by exit status, or let a reward file decide.* Both were forgeable
  by the agent under test, and the security review proved it.

## Consequences

- Every promotion is run twice: once by the instrument to search and size,
  once by the governed plane for the record.
- Holdout spend is never reused for tuning, and a re-salted split is a new
  plan.
- This container had no model keys and no cgroup v2. Live A/A and
  planted-degradation runs, the Terminal-Bench ranking, the
  holdout-to-production join on real sessions, and the governed end-to-end
  under full enforcement are operator runs. The statistics' A/A and
  degradation properties, the replay lane and the verifier's isolation are
  proven here.
- Deferred, each with a named home: per-role profiles (protocol-change/101),
  a `Settings` field for prompt packs, Program verifiers in governed
  comparisons, `loom run` and the Harbor agent adapter, and the GEPA search
  itself, which consumes `Arm.components` and `Grade.side_info` with no new
  abstraction.
