# Project mode: routing with Jev decisions

Status: **proposed 2026-11-24, not built.** The owner asked for project mode to decide where an incoming message goes with typed Jev decisions, in Gleam, through [jevelin](https://github.com/Roasbeef/jevelin). This note is the design for review. The wire and ledger changes it needs are an addendum to [protocol-change/106](../../protocol-change/106-project-mode.md), written with the implementation. The configuration keys are listed here and enter [configuration.md](../configuration.md) with the code that reads them, because `make doc-check` refuses a documented key the decoders do not accept.

In this note, we say what Jev decides, what it is shown, when it runs beside the model router, how the daemon calls it, how a decision is recorded, and how to measure it before it becomes the default.

## 1. What exists

A trigger that the gate admits, and that no subscribed ticket takes, is queued and offered to the router: one long-lived model session whose tools are `route`, `project_read` and `reply` ([project-mode.md, From a trigger to a ticket](../architecture/project-mode.md#from-a-trigger-to-a-ticket)). `route` picks `accept` (with a title), `attach`, `resume`, `stop` or `ignore` for each candidate. Every action is checked by `route.route` against the gate's stored verdict, so the router cannot widen authority. Two things are not decided today. A new ticket's worker always starts with `profile: None, model: None` (`project_start.start_worker`), so every worker uses the `[roles]` chain. And a decline has no reason, only `Ignored`.

[Jev](../jev-mcp.md) is a service that answers typed questions: a Choice over labels the caller supplies, returned with a probability for every label. jevelin builds the HTTP request and decodes the response into the caller's own type. It performs no I/O and its decoder is closed over the labels of the request, so a response cannot name a label that was not asked. That fits the rulings of 106: the decision is data, and it names things by reference.

## 2. The decision

For one candidate trigger the daemon sends one request with two independent questions, combined with `batch.map2`.

| Question | Alternatives (the label is `ticket-N`, `new`, `decline-*`, `agent-N`) | Decoded into |
| --- | --- | --- |
| `target` | one per listed ticket, `new`, and three declines (declines only for an inferred trigger) | `Existing(Int)`, `New`, `Decline(DeclineReason)` |
| `agent` (a later step, section 12) | one per `[[project.agent]]` entry, and `default` | `Pick(Int)` or `Default` |

```gleam
type Target { Existing(Int) New Decline(DeclineReason) }

type DeclineReason { OffTopic NothingToDo Unclear }
```

`Existing(i)` is an index into the ticket list that the host built for this request, not a ticket id. The host keeps that list and maps the index back, so the only ids that can come out of a response are ids the host had just put in. Every alternative carries a description for Jev, passed as `Alternative.description`: a ticket's is its capped title and stage word (section 3), and an agent's is the operator's `use_for` text.

The owner asked that Jev also choose which agent (role, profile or model) takes new work. That is the `agent` question, and it is a separate step that ships after target routing (section 12), so it can be cut without touching the target. Everything above and in sections 3 to 9 works with `target` alone. When `agent` is present, the questions in one batch are independent, so Jev answers it whether or not `target` is `New`, and the host reads it only when `target` is `New`. The extra question costs a few output tokens and saves a second round trip. When `[[project.agent]]` is empty, the question is not asked and new work starts as it does today.

**Tickets listed.** The newest 40 tickets by last activity whose mandate stands (no person's stop), open or ended. An open one is routed with `attach`, an ended one with `resume`, chosen by the host from the ticket's state. For an inferred trigger the list leaves out tickets with an explicit mandate, which is the test `intake.takes` already applies, so Jev cannot pick a ticket the engine would refuse. `route.route` keeps its own check for a race the list cannot see.

**What Jev never decides.** `stop` is never offered: a stop needs a person's explicit message and stays with the owner's `projects.stop` and the model router. Jev writes no title. For `accept` the host derives the title from the first non-empty line of the trigger text, capped by the same `TicketTitle` constructor the router's titles pass through. The worker never reads the title, but it is not only a board label: it is also the worker session's name (`project_start.start_worker`) and the pull request's title (`project_publish`), so it is text a stranger wrote and is handled like the router's. Jev writes nothing that reaches a worker, a thread or a reply, so a decision by Jev posts no message to GitHub. The known gap about a router's `clarify` reply posting model-written text to a thread stays open for the triggers that fall back to the model router. Jev cannot ask a question: `Unclear` is a decline, and a person who wants an answer sends the trigger again or posts it in the composer.

**Declines.** A person's post is not dropped on a probability, so the request for an explicit trigger has no decline alternatives at all. The mapping in `project/jev` therefore cannot produce a decline for one, and this does not rest on the engine, because `route.ignore` checks no strength. Inferred triggers may be declined with one of the three reasons, which the board shows.

## 3. What Jev is shown

The request carries four things, all bounded:

- The trigger's text, at most 4096 code points, as `Content.Text` data and never as instructions.
- A fixed phrase for the trigger's source and relation drawn from the gate's own vocabulary (for example "a comment on a pull request, not addressed to the agent"). Not the sender's login.
- The ticket list above, in `Alternative.description`: the index label, the `stage.of` word, and the capped title. A title is sent only for a ticket whose mandate is explicit, since a person wrote what it was derived from. A ticket opened from an inferred trigger is described by its stage word alone, never by the stranger's first line, so one stranger's text cannot reach the request of another's trigger.
- The agent catalogue's `use_for` strings, which are the operator's own text from `loom.toml`.

It is never shown a secret, an environment value, the configuration, a path, a clone, a worker's transcript, the text of any other trigger or thread entry, or any session text beyond what 106 lets the router read. The router can open a thread through `project_read`; Jev gets the one trigger and nothing around it. That is less context than the router has, which is a cost (section 9) and also what bounds a leak: the text leaves the machine once, and only that text.

Because repository text reaches a third party, `router = "jev"` is an explicit act by the owner and is off by default.

## 4. When it runs, and the default

Jev is the first pass and the model router is the fallback. The host runs the Jev pass inside the `OfferCandidates` effect, before `offer_to_router`, and not on the project actor's own turn: it is a weft task that reports its decisions back as messages. A batch is the up to 20 candidates `queue.offer` already hands over. For each one whose `offer_count` is 1:

1. Build the request and send it (section 5).
2. If the decision is `Existing` or `New`, or an inferred `Decline`, and the selected label's probability is at least `jev_min_probability`, commit it through the same `route_now` path the router's `route` tool uses. The engine's checks are unchanged.
3. Otherwise leave the trigger `Offered`.

A trigger that has been offered before (`offer_count` above 1) skips Jev and goes to the router, since a second offer means the first pass already failed to settle it. When the pass ends, the batch sent to the router session is the triggers whose fate is still `Offered`, whatever the reason. A trigger stays offered when Jev is unavailable (no key, transport failure or timeout, any non-200 including 401, 422, 429 and 5xx), when its response fails decoding, when its selected probability is below the threshold, or when the engine refuses the committed decision (a refusal changes nothing). A below-threshold `agent` answer does not leave a trigger offered: the ticket opens with the `default` agent.

**The turn clock.** `tick` ends a `RouterBusy` turn once `now - offered_at_ms` passes `router_turn_ms` (120 s), and `offered_at_ms` is set only when a batch is delivered to the router. A pass that ran for a while on a quiet project would therefore be ended by the first tick, which returns every undecided candidate to the queue while the pass is still running. The pass sets `offered_at_ms` to 0 when it starts, which `tick` reads as "no clock", and the router's own delivery sets it as before. The `OfferJob` row stays due until the pass ends, so a restart reruns the whole pass, and a re-decision of a trigger already committed is a no-op in the engine. The pass has one bound for the whole batch, well under `router_turn_ms` (section 5). It retries nothing: the model router is the fallback, and the first `unavailable` sends the rest of the batch to the router without another call. When every trigger of the batch is settled by Jev, the host posts `RouterTurnEnded`, which returns the router to idle with nothing undecided.

The router session stays resident in either mode, because it is the fallback and the owner's `reply` path.

**Setting.** `[project] router = "model" | "jev"`, default `"model"`. Reasons for the default: Jev needs a key and sends repository text to a third party, so enabling it is the owner's decision; no Jev decision has a verdict yet, so no rule could be put in `auto` on Jev's judgement; and `"model"` is exactly today's behaviour, so an upgrade changes nothing. The daemon-wide scope is deliberate. A per-project hold would be a sixth key in `project_overrides` for a privacy choice that is cheap to make for the whole daemon, and it can be added later.

## 5. The transport

The call is daemon-side. It does not use a session, a jail or the broker's egress. It uses the transport model providers and the Codex sign-in already use: `provider/http.httpc_transport`, driven the way `client/codex/network.fetch_adopted` drives it, which adopts the request into a weft ledger so cancellation and shutdown wait for the connection's drain witness, and which refuses redirects. No new egress path and no new Erlang FFI. The process machinery is a weft managed task under the project actor, so the actor is never blocked and a stopped project stops its requests (see `docs/weft.md`).

- **Origin.** `jevelin.origin`, fixed in code. It is not a configuration key, so a mistaken or hostile file cannot point a bearer key at another host. Tests inject a fake transport instead.
- **Key.** `Authorization: Bearer <key>` is attached at the transport boundary. The daemon has no daemon-level secret store (`provider/secret.SecretStore` is a type that `client/secrets` fills per session), so the key is resolved once, when the project starts, from the variable named by `jev_api_key_env` (default `JEV_API_KEY`) in the daemon's environment, and held in the project actor's memory. A restart of the project picks up a rotated key. The key appears only in the header value. An unset key is not a boot failure: the daemon logs a one-line warning at project start and every candidate falls back with the reason `no_key`.
- **Bounds.** Per request: `jev_timeout_ms` (default 10000) for the whole exchange, a 64 KiB response limit, and UTF-8 validated before `HttpResponse` is built. There are no retries: the model router is the fallback, and `codex/network`'s `Response` carries no headers, so there is no `retry-after` to honour either. The whole pass over a batch has one fixed bound of 45 s, well under `router_turn_ms`, and the first `unavailable` ends it: the remaining candidates go to the router without a call. One request in flight per project, in the order the candidates were offered.
- **Total decoding.** `jevelin.send` decodes with the request-bound decoder: unknown labels, probabilities outside [0, 1], mass not near one, extra or missing answers and negative token counts are errors, never values. The host then maps `Existing(i)` through the list it built, and an index outside it is a decode failure of ours.
- **Rule Zero.** Nothing from Jev is code, a tool call or text for a model. A decision is a label from a closed set, decoded in the harness VM. The one string in a response that is not a label is `Evaluation.model`, which is validated before it is kept: at most 64 characters of `[A-Za-z0-9._-]`, and a response with any other value is treated as `invalid`. The only strings a response can then contribute are the three decline words, indexes, and that model name.

## 6. How a decision is recorded

A Jev decision is recorded in the same place as the model router's decisions, so the web page lists them together. The engine events gain one optional field:

```gleam
Routed(routing: Routing, judgement: Option(Judgement))
RoutedIgnore(trigger: TriggerId, judgement: Option(Judgement))
```

`None` is the model router's decision, as before. `Judgement` holds the model name Jev reported (`Evaluation.model`, the resolved name when the request used an alias), the selected target (a ticket id, `new`, or a decline reason), the five largest target probabilities each keyed by ticket id or label, the agent chosen with its three largest (once the agent step exists), the threshold in force, and the input and output token counts. Probabilities are stored as integer basis points (0 to 10000) so the ledger and snapshot codecs carry no floats and read the same on either target. `settle` copies it onto the `TriggerRecord` beside the existing `Decision`, so `decision_word` and every existing match on `Fate` are untouched. Ids and not request indexes are stored, so a record reads the same without the list the request was built from. The bounded read of the 20 newest decisions in `projects.board` is another worker's pull request and is not on `main` yet, so this note's claim that it and the thread view read `judgement` from the trigger record is pending that PR; the board's entry gains `decider` (`"model"` or `"jev"`), and, for Jev, `probability` and `reason`. A fallback is also recorded: when Jev was tried and the model router decided, that decision carries `judgement: None` and the ledger has a `host` line `{"host":"jev_fallback","trigger":..,"why":"low_probability"|"unavailable"|"invalid"|"declined_explicit"|"refused"}` so evaluation can count them. The field names above are what this note needs from that work, and the implementation settles the exact keys against what merges.

## 7. Strengths and the rulings

All of them hold because Jev's decision goes through the same code as the router's.

- **Strength.** Jev never sets strength. `work.open` builds the mandate from the gate's stored verdict, as it does for the router.
- **A person's post is not declined.** This lives in the `project/jev` mapping, not in the engine: `route.ignore` has no strength check, so the engine would apply a decline of an explicit trigger. The request for an explicit trigger carries no decline alternatives, so the mapping has no value to produce. A test of the mapping holds it (section 8).
- **Inferred never reaches explicit.** Two layers. The ticket list for an inferred trigger excludes explicit tickets, so the label does not exist in the request. If a decision named one anyway, `route.route` returns `InferredOntoExplicit` and changes nothing, and the trigger falls back. A property test covers the first layer (section 8) and the existing `route` tests cover the second.
- **`auto` only after a live verdict.** `route.route` consults the rule's mode for Jev's decision exactly as for the router's. Under `observe` it records `WouldAccept` and nothing else. The router pin gains a Jev form (section 7.1), so `auto` for a rule needs a passing live verdict measured with Jev as the decider.
- **No free text for a worker.** The schema has no such field. The title is derived by the host. It reaches the worker only as the session's name and the pull request's title, as the router's titles do.
- **Agent choice is not authority** (the later step in section 12). A profile in this repository replaces role chains only (`[profiles.<name>.roles]`), so choosing one changes which models a worker uses and nothing about its jail, tools, approvals or network, which `project_jail` derives from the mandate. A catalogue entry names a profile or a model that must already exist in the file, checked when the file is read.

### 7.1 The pin

A verdict is pinned to the policy version, the router's pack digest and its profile and model key. With `router = "jev"` the pin is the policy version, `jev`, the resolved Jev model name, and one digest over the question texts, `jev_min_probability`, the router's pack digest and the router's model key. The router's two parts stay in the digest because the model router still decides every fallback, so a change to either decider changes what the project does and demotes `auto` rules.

The start-time `pin_router` announcement is not sent in Jev mode, since the resolved model name is not known until a call returns. The first successful call announces it through the existing `RouterPinSet`, which writes nothing when it is unchanged, and the pass commits that event before the decisions of the call that produced it. A decision is therefore never recorded under a pin that the same call has just changed. If `jev-latest` moves to a different model, the next announcement differs, and the engine demotes every `auto` rule to `observe` in that event. An operator who wants no such moves sets `jev_model` to a version. Switching `router` between the two values changes the pin and demotes the same way, which is the intent.

## 8. Tests

jevelin and its decision mapping live in a new module `project/jev` in the portable `project` package: building the two questions from a state and a trigger, decoding, mapping an index back to an id, and the thresholds. jevelin has neither `@external` nor `gleam_erlang`, so R6 holds, and the properties run without processes on both targets. The transport and the weft task live in `client`. Tests use a fake `fn(HttpRequest) -> Result(HttpResponse, e)`; nothing in the suite touches the network.

Properties with qcheck: a decoded decision always names a ticket that was in the request's list; an inferred trigger never routes to an explicit ticket whatever response the fake returns; a response with any label outside the request fails decoding; the fallback fires for each reason in section 4; the mapping never produces a decline for an explicit trigger; a decision is never committed when its request had a response with an invalid model name. A pass test checks that `offered_at_ms` is 0 for the whole pass and that `tick` ends no turn during it. A model-based test extends the existing project machine with the Jev pass in front of `route`, checking that `RouterTurnEnded` accounting leaves no trigger `Offered` without an offer. A live check on a throwaway daemon with its own state directory and port runs only when `JEV_API_KEY` is set in the environment, and never prints it.

## 9. Evaluation before the default moves

The comparison uses the instrument that exists. A person labels recorded triggers `accept` or `reject` (`projects.label`), and `projects.verdict` measures a candidate against the labels over the recorded tape ([the verdict addendum](../../protocol-change/106-project-mode.md#addendum-the-verdict-2026-11-02)). The live lane's candidate is today a scratch router session. This work adds a second candidate, Jev, to the same lane:

- `projects.verdict` takes `router: "model" | "jev"`, defaulting to the setting in force. The Jev candidate builds the same request for each labelled trigger, three trials each, through the same transport and the same bounds, and counts any action but `Decline` as taking the trigger on, as the tape counts the router. A trial that falls back counts as a failed trial and is reported as `unavailable` so a flaky service cannot pass.
- Both candidates are run on one label set, so the report puts the two `agreement_points` (taken per label class), the interval against the recording, the rate of fallbacks, the token spend and the wall time side by side.

The switch of the default needs all three: Jev passes the live lane at the thresholds the model router passes at (`min_agreement_points` 75, `max_bound_points` 30); its agreement on the same labels is not lower than the model router's by more than the interval's width; and fewer than 5 percent of trials fell back. Changing the default is its own change, with the figures in its description and the owner's approval. A pass in this lane says how Jev judged these triggers with one trigger's text and the current ticket list, which is less than a router that reads threads. The live lane does not replay each trigger's historical ticket list because the tape does not keep it, so the list is the one at run time and the report says so. The agent choice is recorded and not measured: the labels are accept and reject, so a wrong agent does not change the verdict. Measuring it needs labels for the agent, which is out of scope here.

## 10. Configuration and protocol change

Keys, all under `[project]`, all optional:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `router` | `"model"` or `"jev"` | `"model"` | Who decides first. |
| `jev_min_probability` | integer percent, 51 to 100 | 80 | The least probability of the selected target for a Jev decision to be applied. |
| `jev_model` | string | `"jev-latest"` | The model or alias sent with each request. A version name makes verdicts stable across Jev's releases. |
| `jev_api_key_env` | string | `"JEV_API_KEY"` | The variable the key is read from in the daemon's environment, once when the project starts. |
| `jev_timeout_ms` | integer, 1000 to 30000 | 10000 | The bound on one request. The whole pass has a fixed bound of 45 s. |
| `[[project.agent]]` | at most 16 tables | none | `name` (1 to 40 characters), `use_for` (1 to 200 characters), and `profile` and/or `model`, each naming an entry that exists. An empty list means no agent question. |

The addendum to 106 is **additive**. It affects: the ledger events `Routed` and `RoutedIgnore` (one optional `judgement` field each, which is display-only. A build before this change ignores an unknown field of a known event, as `codec.gleam` decodes it, so it reads such a ledger and drops the field. No state lives in that field); one new `host` line (`jev_fallback`); in the agent step, a new event tag that records the agent chosen for a trigger, committed before its `Routed`. A new tag is refused by a build that does not know it, so an older build cannot start a ticket on the wrong agent, which it could if the agent rode in an optional field; the snapshot, by `judgement` on a trigger record; the `projects.board` decision entry (`decider`, `probability`, `reason`, additive under section 1.5 of `client-protocol.md`) and `projects.verdict` (`router`); the router pin; and `loom.toml` by the keys above. No change to a Part 1 interface, a session's tools or the jail. A ticket gains `agent`, set from that event when it opens and read by `start_worker` for `Creation.profile` and `Creation.model`.

jevelin is not on Hex. The implementation begins with the path dependency the owner named, `../jevelin`. A signoff host and a release build have no sibling checkout, so before merge the dependency becomes a pinned git reference, as `etui` and `mist` are, or jevelin is published. Every downstream manifest's requirements line is updated by hand when it is added, per the path-dependency drift note.

## 11. What it costs, and what is left open

- A Jev call per candidate, with a latency of its own, and repository text sent to a service the owner has to trust. Both are why the default stays `"model"`.
- The resident router session still costs its memory while `router = "jev"`.
- Jev sees less than the router: one trigger, a title list, no thread. A trigger whose meaning depends on its thread may score low and fall back, which is the intended direction of failure.
- A candidate may be sent to Jev and then to the model router, so a bad service raises cost until the threshold or the setting is changed. The fallback count on the board is how an operator sees it.
- `token_ceiling` does not yet count Jev's tokens. Known gaps already say nothing in the daemon consumes the ceiling.
- Open, for the owner. The reviewer's recommendation follows each question, and none is decided here.
  - Should `router = "jev"` be a per-project hold instead of daemon-wide? Recommendation: keep it daemon-wide.
  - Should `Unclear` fall back to the model router, which can ask, and not decline? Recommendation: fall back.
  - Should the agent question wait until agent choice can be measured? Recommendation: defer it. The design keeps it as a separate later step so that it can be cut cleanly.

## 12. Slices

1. `project/jev` with fake-transport and property tests, `target` only; no daemon wiring.
2. The ledger fields, the addendum to 106, the pin, and the board entry.
3. The weft pass and transport, `router = "jev"`, the fallback and its record, the configuration keys and their rows in `configuration.md`.
4. The `projects.verdict` Jev candidate and the live check.
5. The agent step, after target routing ships and separable from it: the `agent` question, the `[[project.agent]]` catalogue, the agent event and `start_worker`.
