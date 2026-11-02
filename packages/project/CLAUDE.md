# project

## Purpose

The engine of project mode ([design note](../../docs/design-notes/project-mode.md),
[protocol-change/106](../../protocol-change/106-project-mode.md)): a pure,
replayable state machine that turns outside events into units of authorized
work. `engine.apply(state, event)` returns the next state and a list of
effects, or a refusal that leaves the state untouched. `engine.replay` folds a
list of events into a state, so the ledger stores events and nothing else.
An actor in `client` (not built yet) holds the state, persists each accepted
event before acting, performs the effects, and feeds their outcomes back as
events. The package performs no I/O and reads no clock; times are system
milliseconds that the caller passes in.

Portable by rule. No `@external`, no `gleam_erlang`/`gleam_otp`, no Loom
package, no `panic` or `let assert` in `src`: lint R6 holds it to the same
subset as `core`, `machine`, `prompt`, `gepa` and the others in
`lint/policy.portable_packages`. Two properties rest on that: the state space
is explored by a model-based test over random event sequences with no
processes, and the ledger codec reads the same events on either target. The
suite runs on both, and `scripts/check.sh` runs it on JavaScript through
`scripts/portable_js_test.sh`. The one dependency beyond the standard library
is `gleam_json`, which has both targets.

## Modules, in reading order

- `project/model` is the vocabulary: identifiers, `Trigger` with its gate
  `Inputs`, `Mandate` and `Scope`, `Report`, `Head`, `Routing`, `RouteKind`
  and `Relation`, the demand and outcome words, and the derived names
  `ticket_for`, `request_key` and `branch_name`. `TicketTitle` is opaque and
  capped.
- `project/gate` decides strength and acceptance. `classify` is the authority
  table plus the generation limit (`max_generation`); `acceptance` says
  whether an inferred trigger may be accepted (`Auto`, a rule and a current
  verdict), recorded only (`Observe`) or refused.
- `project/host` holds `CheckPassed`, an opaque proof whose only constructor,
  `host.passed`, belongs to the host's event path and to the codec.
- `project/readiness` owns `Readiness` and its transition table. `Ready`
  needs a `CheckPassed`; a person's publish is a separate state.
- `project/stage` is the pure stage function with the wire spelling,
  including `ended/<outcome>`.
- `project/policy` maps a `Mandate` to a `WorkerPolicy` of plain data, taking
  nothing else by type (`for_mandate`; `derive` is a reserved word in Gleam).
- `project/event` has `Event`, `Effect` and `Refusal`.
- `project/state` has `State`, `Ticket`, `Assignment`, the stored trigger
  records and the pure queries every transition shares.
- `project/engine` dispatches events and owns modes, verdicts, the policy
  version and the token ceiling. It calls `project/intake` (a trigger arrives,
  is gated and recorded on its thread, then delivered to subscribers or
  queued), `project/queue` (the bounded per-source candidate queue and the
  router's batches), `project/route` (the router's decisions),
  `project/schedule` (worker slots) and `project/work` (a ticket from
  assignment to conclusion).
- `project/codec` is the ledger's JSON form of an event, with total decoders.

## Invariants that break things when violated

- **`Ready` needs the host's proof.** `readiness.check_passed` is the only way
  into `Ready` and takes a `host.CheckPassed`; a worker `Report` has no
  `Ready`. A later commit (`readiness.new_commit`) invalidates a pass. A
  publish past a failing check is `PersonPublished`, which lands in
  `Published`, not `Ready`.
- **Strength is set once, by the gate.** `intake` stores the gate's verdict;
  `work.open` builds the mandate from it. No routing event carries a
  strength. Accepting, attaching or resuming with an inferred trigger needs
  `gate.Proceed`; `Observe` records `WouldAccept` and changes nothing else.
- **Only admitted triggers travel.** A non-admitted trigger is recorded on
  its thread and has no `Deliver` or `OfferCandidates` effect.
- **A person's stop is final.** `work.withdraw` ends the ticket as
  `StoppedByPerson`, clears its demand and inbox, and every other transition
  refuses a withdrawn ticket. Stop is reachable only from `PersonStopped` or
  from an offered trigger the gate admitted as explicit.
- **Overload sheds from the inferred end.** `queue` sheds inferred triggers
  first and records each as `Shed`; an explicit trigger is never dropped and
  queues past the bound when nothing inferred is left to shed. A source
  stops inferring while its open tickets that need a person exceed
  `attention_limit`, and the token ceiling holds inferred work.
- **Slots.** `max_workers` general slots plus one reserved for a ticket whose
  demand is `ByPerson`. `schedule.run` is the only place an assignment is
  made, and it skips withdrawn and ended tickets.
- **Check rule.** `work.check_rule` requests a check only for a `Waiting`
  report with no question and a head that differs from `last_checked`; a diff
  touching protected paths goes to `AwaitingReview` and requests none.
- **Session ids are not derived.** The catalogue mints them. An assignment
  carries `model.request_key(project, ticket, seq)` for idempotent creation,
  and `SessionBound` records the id once the host has one.
- **A new event is one constructor, one `to_json` arm, one decoder arm.**
  `to_json` is exhaustive. Enumerations share one table per type in the codec.

## Tests

`test/project/engine_test.gleam` drives one rule per test.
`test/project/machine_test.gleam` is the `statem` check: random sequences over
the engine, with each invariant above checked after every accepted event
against a shadow of the log, and a replay check at the end of each run. Its
second test asserts the generator reaches the guarded states. Fixed seeds
throughout. `test/project/tables_test.gleam` covers the gate, stage, policy,
readiness and names; `test/project/codec_test.gleam` the codec properties.

## Dependencies

`gleam_stdlib` and `gleam_json`; `gleeunit`, `qcheck` and `statem` for tests.
`client` and `tools` depend on it (types and the codec); the engine's actor is
`client/daemon/project_host`.
