# gepa

A GEPA-style reflective search over the text components of a program,
written in Gleam as a pure, replayable state machine. You bring the
program, the tasks, a way to score a candidate on a task, and a model
that can rewrite one component given evidence; the library decides
everything else — which candidate to extend, which tasks to try it on,
whether a child is worth paying for, what each stage may spend so the
final confirmation is always still affordable, and when to stop — and
never performs an effect of its own.

It depends on `gleam_stdlib` alone and builds and tests on both the
Erlang and JavaScript targets.

## The shape

A **candidate** is a list of `#(component_name, text)` pairs. A **task**
is an opaque string id. A **score** is a float in `[0, 1]`, higher is
better, already aggregated by you over however many trials you ran, with
optional feedback text the reflector may be shown. **Money** is whatever
unit you meter — dollars, tokens, seconds — and the library only ever
compares and subtracts it.

The host runs a loop:

```gleam
fn run(state: gepa.State, config: gepa.Config, events: List(gepa.Event)) {
  let assert Ok(request) = gepa.next(state, config)

  case request {
    gepa.Done -> #(state, events)

    // The search decided something that needs no effect: apply it.
    gepa.Record(event:) -> step(state, config, events, event)

    // Evaluate `candidate` on `tasks`, spending at most `cap`; for the
    // `Confirm` stage evaluate `state.seed` alongside and measure both.
    gepa.Evaluate(stage:, step: at, candidate:, tasks:, trials:, cap:) -> {
      let #(measured, cost) =
        my_evaluate(state, candidate, stage, tasks, trials, cap)
      step(
        state,
        config,
        events,
        gepa.Evaluated(
          stage:,
          step: at,
          candidate:,
          tasks:,
          cap:,
          ref: "my-run-id",
          measured:,
          cost:,
        ),
      )
    }

    // Show the model the prompt, record the call, then admit the answer.
    gepa.Reflect(step: at, slot:, request:, worst_case:, proposal:, of:, ..) -> {
      let #(text, cost) = my_model(prompt.render(request), worst_case)
      let reflected =
        gepa.Reflected(
          step: at,
          cost:,
          ref: "",
          finish: gepa.Unknown,
          proposal:,
          of:,
        )
      let assert Ok(state) = gepa.apply(state, reflected)
      let events = list.append(events, [reflected])
      let assert Ok(minted) =
        gepa.admit(state, slot, prompt.answer(text), gepa.content_id)
      step(state, config, events, minted)
    }
  }
}

fn step(
  state: gepa.State,
  config: gepa.Config,
  events: List(gepa.Event),
  event: gepa.Event,
) {
  let assert Ok(state) = gepa.apply(state, event)
  // Persist `log.encode(event)` here: the log is the state.
  run(state, config, list.append(events, [event]))
}
```

This is `test/gepa/readme_test.gleam` verbatim, which compiles and runs
it on both targets with the simplest `my_evaluate` and `my_model` a host
could write; copy from there rather than from here if the two ever
differ.

Start from `gepa.start(seed_id, seed_components)` with a `gepa.Seeded`
row as the log's first line. To resume after a crash, `log.parse` the
file, `gepa.replay_checked` the events against the same `Config`, and
call `run` again: `next` re-enters an open step at the stage its rows
reached and asks for the same thing. The draws are recomputed from the
search id and the step number, so a resumed step draws the same parent
and minibatch it drew before. `replay_checked` holds every row to the
request `next` made before it (the stage, step, candidate, tasks and cap
of an evaluation, the cost against the cap or the reflection's worst
case, the parent and slot of a child, the judgements and the stop the
search itself decided), so a log edited by hand, or written by a host
that strayed from the loop, is refused by name rather than replayed.
`gepa.replay` is the same fold without that check, for a host whose rows
did not come from `next`.

The test support module `test/support/world.gleam` is a complete host of
this shape, and `test/gepa/loop_test.gleam` is what it is held to.

## The loop, in words

One step, given a pool whose members all have validate scores:

1. a parent is drawn from the Pareto front over the validate tasks, in
   proportion to the tasks it leads (GEPA's Algorithm 2), from a
   generator seeded by the search id and the step;
2. the parent is evaluated on a minibatch of tune tasks to collect
   feedback (`ParentMinibatch`); a parent that scored one on every
   minibatch task has nothing to reflect on, and the step ends there in
   a `Refused` row spelled `skipped_perfect` that cost no call;
3. the reflector is shown that feedback, the slot's current text, the
   slot's background (`Config.background`) and a digest of the rewrites
   of that slot this lineage already rejected, and answers the slot's
   new text; the child is the parent with that slot replaced (`Minted`),
   or the step ends `Refused` — as it does when your `Reflected` row
   says the answer was `Truncated` at an output limit;
4. the child is evaluated on the same minibatch (`ChildMinibatch`); the
   **screen** passes it on only if its mean is strictly above the
   parent's, or ties it while scoring on a task the parent scored zero
   on — a spend filter, never a claim;
5. the child is evaluated on the whole validate split (`Validate`) and
   **judged** by your acceptance rule against the parent and, when the
   parent is not the pool's best, against the incumbent. `Improved` joins
   the pool (`Incumbent` when also not worse than the incumbent and
   leading more tasks, else `Joined`); `Inconclusive` joins as a Pareto
   member never ranked above its parent; `Harmed` and `Incomplete` stay
   out.

At a stop (steps, budget, reflections or candidates), the seed and the
best are evaluated together once (`Confirm`), the only simultaneous
comparison, and that judgement is the headline.

With `Config.proposals` above one, a step asks the reflector that many
times in turn — each call its own `Reflect` request, carrying `proposal`
and `of`, with the step's earlier siblings in the digest — runs every
child it minted on the minibatch, settles all but the winner
`ScreenedOut` (the highest minibatch mean among the passers, the earliest
minted on a tie), and pays validate for the winner alone. A refused
answer closes the step only when it was the last proposal and no child
was minted. The width is written on the step's first `Reflected` row, so
the fold knows it from the log and a resumed search finishes a step at
the width it began at; a width of one writes exactly the rows it always
did.

## The budget model

Everything is in `gepa/budget`, and the host supplies three numbers:

- `Costs(trial:, attempts:, reflection:)` — the worst case of one trial of
  one task, how many attempts you may make at a cell before giving up
  (every attempt is charged), and the worst case of one reflection call.
- `Limits(budget:, max_steps:, max_reflections:, max_candidates:)`.

The library then **holds money back rather than checking it**. A stage is
handed `cap = remaining - held_back(stage)`, where the hold is the
confirm run's worst case plus the worst case of every later stage in the
step, each cell at its retried worst: with `n` proposals a step is the
parent's minibatch, `n` reflections and `n` child minibatches, one
validate run and the confirm, and the hold before proposal `i` counts the
`n - i + 1` reflections left and all `n` minibatches. A stage whose cells
retry is cut off by its own cap before it can spend what a later stage,
or the confirm run, was reserved. A step is taken only when
`remaining >= step_worst_case + confirm_worst_case` and the reflection
and candidate ceilings have room for the whole step; each reflection is
made only when its worst case is still covered (otherwise a zero-cost
`Reflected` row and a `Refused` naming the budget are recorded, so the
log still reads the step); a confirm run the budget no longer covers is
never started.

Your side of the contract is one line: an evaluation spends no more than
the `cap` it was handed. Under that, the library's tests hold over random
designs that spend never passes the budget and a best that is not the
seed is always confirmed.

## What the host supplies

- **Evaluation.** Given a candidate, a stage, tasks, trials per task and a
  cap, return `List(gepa.Measured)` — per candidate, a `gepa.Score(task,
  value, feedback)` per task — and what it cost. For `Confirm`, measure
  the seed too.
- **Reflection.** Render `prompt.Request` with `prompt.render`, call your
  model, record the call as `Reflected` with its cost and how the answer
  ended (`Complete`, `Truncated` at an output limit, or `Unknown`), judge
  the text with `prompt.answer`, and turn it into an event with
  `gepa.admit`, which refuses a truncated answer however well it reads.
  The prompt frames every excerpt in `[[record]]` tokens, breaks the
  tokens inside bodies, bounds each field to 4 KiB and the dataset to 8
  rows, and replaces the identifiers you list as hidden per task
  (`Config.hidden`) with `<test N>` so the model cannot learn a test's
  name and write it into the program. `Config.background` gives each slot
  its constraints in your words (a tool's description may not misdescribe
  the tool, say), shown as framed notes; `Config.evidence` decides which
  fields of a score each slot's reflection reads, so a host can pack what
  it has into `Score.feedback` and show a tool slot the tool's errors and
  a prompt slot the verifier's tail (`gepa.feedback_evidence` shows the
  feedback whole); and the request carries a bounded digest of the
  rewrites of the slot this lineage already refused, screened out or
  found harmful, so the model is told what not to repeat.
- **Acceptance.** `Config.judge: fn(List(judge.Pair)) -> verdict.Acceptance`
  over paired per-task scores. `judge.sign_test` is the default: the
  exact two-sided sign test at 0.05 with the direction read from the
  mean. Loom supplies its own statistical rule here; you may too.
- **Candidate ids.** `gepa.admit` takes an id function; `gepa.content_id`
  (128 bits of salted FNV-1a over the components) is enough to tell the
  candidates of one search apart, and a host with a stronger hash should
  use its own.
- **Persistence.** `gepa/log` encodes one event per line of printable
  ASCII, total to decode; write each line as you apply its event, and
  `log.parse` refuses a file whose last line is torn.

## Depending on it from another repository

The package lives at `packages/gepa` inside Loom's repository, so a plain
Hex dependency is not yet available. Two routes are open:

- **Vendor it.** Copy `packages/gepa` into your tree and depend on it by
  path (`gepa = { path = "../gepa" }`). It has no dependencies but
  `gleam_stdlib`, so the copy carries nothing else.
- **A git dependency** pointed at this directory, if your Gleam version's
  manifest supports one; this has not been exercised from outside the
  tree, so treat it as something to test rather than something promised.

Either way, the public surface is what `gleam export package-interface`
prints for the package, and the tests under `test/` are the contract.
