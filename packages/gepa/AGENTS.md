# gepa

## Purpose

A GEPA-shaped reflective search over the text components of a program,
extracted from `eval/search`, `eval/reflect` and `eval/optimize` so that a
project which is not Loom can run the same search over its own programs
without taking Loom with it. The library is a pure state machine the host
drives: the host asks `gepa.next` and gets a typed request (evaluate this
candidate on these tasks under this cap; show the reflector this prompt),
performs it in its own world, and feeds back a typed event; `gepa.apply`
refuses an event the state cannot accept, `gepa.replay_checked` refuses
one the search did not ask for, and a replay of the event list rebuilds
the state exactly, so resume is the same loop over the replayed log. Candidates are maps from component name to text, tasks are
opaque ids, scores are floats in `[0, 1]`, and money is whatever unit the
host meters.

Portable by rule. No `@external`, no `gleam_erlang`/`gleam_otp`, no Loom
package, no `panic` or `let assert` in `src`: R6 holds it to the same
subset as `core`, `machine`, `prompt`, `session_view`, `statem` and
`evalstat` (`lint/policy.portable_packages`), for the plain reason that it
is meant to be embedded elsewhere. Randomness is a seeded generator in
pure Gleam, and the suite runs on both targets: `gleam test`, and
`gleam test --target javascript --runtime node`, which `scripts/check.sh`
runs through `scripts/portable_js_test.sh` after the Erlang suite, so the
promise is gated (`make test-portable-js` runs it alone).

## Modules, in reading order

- `gepa` — the state machine. `Event` (`Seeded`, `Evaluated`, `Reflected`,
  `Minted`, `Refused`, `Judged`, `Stopped`), `State` (members, pool,
  incumbent, evaluations, spend, the open `Progress` with its `Reached`
  stage, the `Confirmation`), `Config` (search id, objective, tune and
  validate task ids, `k`, `k_tune`, minibatch, slots, hidden ids,
  `budget.Limits`, `budget.Costs`, the host's `judge.Judge`), `Request`
  (`Evaluate`, `Reflect`, `Record(event)`, `Done`). `start`, `replay`
  (the per-event fold), `replay_checked` (the fold that also holds each
  row to the request `next` made before it; `expected` is that check
  alone), `apply`, `next`, `admit` (an answer into `Minted` or
  `Refused`), `child_components`, `content_id`, `is_finite`,
  `validate_scores`, `minibatch_scores`, `spent`, `children`.
- `gepa/verdict` — the words: `Acceptance` (`Improved | Harmed |
  Inconclusive | Incomplete`), `Disposition` (`Incumbent | Joined |
  ParetoOnly | Discarded | Unsettled | Refused | ScreenedOut | Confirmed |
  Unconfirmed`), `Basis` (`OnMinibatch | OnValidate | OnConfirm`);
  `dispose`, `consistent`, `confirm`, and the spellings.
- `gepa/select` — GEPA's Algorithm 2: `front(members, tasks, k)` (leaders
  within `1/k` of the best per task, Pareto-pruned), `draw_parent`
  (proportional to tasks led), `minibatch` (without replacement),
  `slot_for` (round robin), `screen` (the spend filter), `rank` with
  `Standing` (the front's order: incumbent, improved tier by standing and
  tasks led, Pareto tier by step).
- `gepa/budget` — the holds: `Costs(trial, attempts, reflection)`,
  `Design(validate_tasks, minibatch_tasks, trials, tune_trials)`,
  `Limits`, `Counts`, `StopReason` (`Steps | Budget | Reflections |
  Candidates`), `Stage`; `cell_worst_case`, `confirm_worst_case`,
  `held_back`, `step_worst_case`, `cap`, `remaining`, `stop_reason`
  (strict), `covers` (the one-part-in-a-billion tolerance, used only by
  the two reservation questions), `reflection_affordable` (the whole of
  the rest of the step, confirm included), `confirm_affordable`.
- `gepa/prompt` — the reflector's text: `Record(task, score, fields,
  hidden)`, `Request(objective, slot, current, records, notes)`;
  `prepare` (bounded, redacted, frame-safe), `redact_ids`, `excerpt`,
  `frame_safe`, `render`, `answer`; `max_excerpt_bytes = 4096`,
  `max_rows = 8`, `max_answer_bytes = 16_384`, the `[[record]]` frame.
- `gepa/judge` — `Pair(task, baseline, candidate)`, `Judge =
  fn(List(Pair)) -> Acceptance`, `pairs`, and the default `sign_test`
  (exact two-sided sign test over per-task differences at `alpha = 0.05`,
  direction from the mean).
- `gepa/prng` — xorshift128 on 32-bit words seeded by salted FNV-1a, a
  copy of `evalstat/prng` kept algorithm-identical; `from_string`, `next`,
  `below`, `unit`, `fnv1a`.
- `gepa/log` — the line format: `encode`, `decode`, `parse`, `render`, the
  stage and finish spellings. One event per line of printable ASCII,
  `kind v=1 key=value …`, the separators and backslash escaped by name
  and every other code point outside `!`..`~` as `\u{hex}`; both
  directions walk code points, and `parse` refuses a text whose last row
  has no newline.

## Invariants that break things when violated

- **The log is the state.** `apply` refuses a row out of order, a
  candidate no `Minted` introduced, a settling judgement whose evaluations
  are missing (`search row missing: …`), a disposition that does not
  follow from its acceptance (`verdict.consistent`), an incumbent
  judgement missing or repeated, a row after the stop, an empty id, a
  negative or non-finite cap, cost or score. `replay_checked` further
  refuses a row that is not the answer to the request before it: an
  evaluation of another stage, step, candidate, task list or cap, or one
  that spent past its cap; a reflection of another step or above its
  worst case; a child minted from another parent or slot; a judgement or
  a stop the search did not decide (so a stop with the confirm run
  unjudged, or a validate run with no passed screen, cannot be replayed).
  A host that drove `next` resumes with `replay_checked`; Loom's adapter,
  whose rows did not, folds with `replay`. A replay of any prefix of a
  log the loop wrote, driven on, ends in the same log, except a cut right
  after `Reflected`: a lost answer is reflected again, or refused when a
  second call would eat the reservation, and the budget holds either way.
- **Money is held back, not checked.** A stage's cap is `remaining -
  held_back(stage)`, the confirm run's worst case plus every later stage
  of the step at its retried worst; a step is taken only when `remaining
  >= step_worst_case + confirm_worst_case`, strictly; a reflection is made
  only when what remains covers it and every stage after it, the confirm
  included (`reflection_affordable`), which a first reflection always
  does under the caps and a second one of a resumed step may not, else a
  zero-cost `Reflected` and a `Refused` naming the budget; a confirm run
  the budget no longer covers is never started. `loop_test` holds, over random designs with worst-case
  and over-spending hosts, that spend never passes the budget and a best
  that is not the seed is always confirmed. Dropping the confirm term from
  `stop_reason` fails it.
- **The two reservation questions allow one part in a billion**
  (`budget.covers`, in `confirm_affordable` and `reflection_affordable`
  only): what remains is a sum of the host's charges, and a sum that
  should land exactly on a hold the search made can land a few ulps under
  it. Step admission is strict; nothing is owed before a step starts.
- **The minibatch is a spend filter, not a decision rule.** `screen`
  decides whether to pay for validate; the only acceptance is the host's
  judge on validate, child against parent and, when the parent is not the
  incumbent, against the incumbent. `Improved` joins the pool
  (`Incumbent` when not worse than the incumbent and leading more tasks,
  else `Joined`); `Inconclusive` joins as `ParetoOnly`, never ranked above
  its parent; `Harmed` and `Incomplete` stay out.
- **Draws are a function of the seed.** `next` seeds the generator with
  `config.id <> "/" <> step` and draws the parent, then the minibatch; a
  resumed step draws the same, and `within_step` refuses a parent the log
  does not hold. `prng` must stay the stream `evalstat/prng` emits
  (`first_outputs_are_fixed_test` pins it; `eval`'s `search_test` compares
  the two).
- **The judge never sees a hole.** `judged` hands the host's rule pairs for
  every validate task or `Incomplete`, never a shorter design.
- **The prompt is data in frames.** `render` frame-safes everything the
  host supplied, redacts the record's hidden ids before bounding, keeps
  the tail of an over-long field, and `answer` refuses an empty, oversize
  or frame-carrying reply. Every search, replacement and cut walks code
  points, never the standard library's grapheme- or code-unit-based
  strings, so a combining mark cannot hide a frame token or an id on
  either target; a redacted form matches only on identifier boundaries
  (ASCII letters, digits, `_`, `@`), and a dotted id splits at its last
  dot.
- **A new event kind is one constructor plus one encode and one decode
  arm**, tagged by kind under `v=1`; unknown kinds, keys, escapes,
  versions, non-ASCII code points and non-finite numbers are refused by
  name, and a golden test pins the exact line for the values that once
  told the two targets apart. The module doc of `gepa` names where the
  anticipated extensions go (several proposals per reflection, further
  dispositions, a richer reply, merge lineage).

## Dependencies

`gleam_stdlib` only; `gleeunit` and `qcheck` for tests. `eval` depends on
it (`eval/search` is the adapter, `eval/optimize` the effectful driver);
it depends on nothing in Loom. `README.md` is written for a consumer
outside the tree.
