# Jev in the harness: where else a daemon-side decision could use it

Status: **proposal, 2026-11-24. Not a commitment, and it writes no code.** A research pass on Jev's documentation and on Loom's decision points followed the [design for routing project work with Jev](project-jev-routing.md). This note records what Jev is, which candidates the pass found, which it dismissed and why, and the order it recommends. The sources are Jev's published documentation (https://docs.typesafe.ai), the jevelin and jevlar repositories, and the Loom tree as of this date.

In this note, we keep the facts apart from the inferences, so the owner can check each claim against its source.

## 1. What Jev is

**Facts.**

- **Purpose.** Jev is TypeSafe's "System One" model. It evaluates typed questions against one `state` and returns typed answers with probabilities. It generates no text and gives no reasoning. (docs.typesafe.ai/introduction, concepts/system-one)
- **Endpoints.** `POST /v1/systemone` and `GET /v1/models` on `https://api.typesafe.ai`, with a bearer key and no streaming. (jevelin `docs/API.md`; `src/jevelin.gleam`)
- **Request.** `state` is a string, an object or an array, and an object is recommended for most requests. The request also carries `model` and named `questions`. (concepts/state, api)
- **Independence.** All questions in a request see the same state and are evaluated in parallel and in isolation. A decision that depends on another answer needs a second request. (jevelin `docs/API.md`; `src/jevelin/batch.gleam`)
- **Question types.** A Choice has 1 to 255 labelled options with optional descriptions and returns the top label, a `confidence` and a probability for every label. A Score has 2 to 10 ordered levels and returns a fractional expected index. A Noul returns the probability of yes, with optional criteria for each side. A Box locates something in an image and exists only in Jev 1.14. (api, models)
- **Confidence.** For a Choice, `confidence` is `(p_max - 1/n) / (1 - 1/n)`, a transform of the top probability, and is not the chance of being correct. The documentation says to threshold on the probability of the option you will act on, or on the ratio of the top two. (confidence)
- **Calibration.** Calibration is a training goal "measured across groups of predictions", with no published metrics. The documentation says to start conservative and tune thresholds on your own data. (concepts/system-one, confidence)
- **Models.** `jev-1.14.0` (from 2026-10-14) and `jev-1.13.0`. `jev-latest` and `jev-preview` both point to 1.14.0 and move on release, and the response's `model` field names the resolved id. There is no per-account fine-tuning, and requests are not used for training. (models)
- **Price and limits.** $0.042 per million input tokens, and output tokens are free. A request may hold 64k tokens and one question 32k (state plus that question), with no limit on the number of questions and a 32 MiB body. Rate limits are per organization and shown only in the console. (models, api/errors)
- **Latency.** No published figure. The skill-suggestion cookbook measured 0.07 to 0.25 s per request and says adding questions barely changes it. (cookbooks/skill_suggestion, introduction)
- **Errors.** 400 (including `max_tokens_exceeded`), 401, 413, 415, 422, 429 and 529. The official SDKs retry 408, 429 and 5xx with backoff and honour `retry-after`. (api/errors; jevelin `docs/API.md`)
- **Run-to-run variance.** Low but not zero: 1.0 percent on average over options and 6.7 percent at worst, across 15 repeats of identical requests. (cookbooks/consistency_choice_cookbook)
- **Documented weaknesses.** It reads questions literally, leans toward the first Choice option, loses accuracy as unrelated state grows, is weak at counting, dates, multi-hop reasoning and negation, and does not treat state as hostile, so injected or misleading text can shift answers. (model-jaggedness)

**Practices.**

- One judgement per question, with compound judgements split and combined in code. (introduction, patterns)
- Descriptions that separate each option from its neighbours, and short snake_case labels. For options that are easy to confuse, an object with fields such as `what` and `not_for`. (primitives/choice)
- A "none of the above" option may not work, because a Choice always returns its closest option. The documented fix is a companion Noul in the same request, with the Choice read only when the Noul is a clear yes. (patterns/companion-noul, primitives/choice)
- Thresholds scale with risk. The documentation uses three tiers (act, caution, fall back), with example values of 0.67 for a low-stakes action and 0.93 for a destructive one, and 0.7 and 0.3 for a Noul whose middle band is its own outcome. (confidence, patterns/probability-routing)
- Ranking many candidates uses one Noul per candidate with fixed criteria and candidate text in `state`, then sorts by probability. (cookbooks/rerank_typesafe)
- Pin a versioned model id for stable results. (models)

**Inference.** A request of about three thousand input tokens costs roughly $0.0001, so cost does not constrain a design. Latency and the disclosure of text to a third party do.

## 2. Where Jev is used today

- **jevlar** `examples/triage/main.go` and its README: one request with a `route` Choice, an `urgency` Score and a `spam` Noul, combined by `Map3`, with no threshold and no abstain option.
- **jevelin** README: a `workflow` Choice plus a `needs_clarification` Noul through `batch.map2`. That is the companion-Noul shape, and it asks "unclear" as a Noul and not as an option.
- **jevelin-mcp**: four tools (`jev_choice`, `jev_score`, `jev_noul`, `jev_batch`), one attempt, a 30 s default timeout, a 4 MiB response cap and `jev-latest` by default.
- **Loom**: Jev is reachable only from a model-written `code_mode` program through `cap/mcp/jev` ([jev-mcp.md](../jev-mcp.md)). No daemon-side caller exists. One live run on 2026-10-01 answered as `jev-1.13.0` with 324 input tokens.
- **TypeSafe cookbooks closest to routing**: skill suggestion (a Choice over 194 skills with gate Nouls, then a second request over the top three with a "fits" Noul each; it returns nothing below 0.30 to 0.50, and measured 2.0 times fewer wrong loads on 452 requests); function calling (a Choice over 10 functions plus a Noul per flag, about 54 questions in one request, with call confidence the minimum of its judgements); classification using confidence (acting at 0.9 or above was right 26 of 28 times, and below it 16 of 32); and LLM guardrails (Nouls with yes and no criteria, review at 0.35 and act at 0.70).

## 3. A shared client first

The routing design builds its transport as `client/jev`: key resolution at the daemon, the fixed origin, a timeout, a response cap, a weft task, and a type for the reason a call produced no answer. It has one function, which takes a prepared `jevelin.Request` and a deadline. It has no registry and no cache until a second caller exists. That costs nothing beyond the routing slice, and it is why the configuration for the service sits in its own `[jev]` table and not under `[project]`. Every candidate below would call the same function.

## 4. Candidates, ranked by value against cost

Each has the same shape of risk: Jev's output is a closed set, so a wrong answer changes an order or skips an optional step, and none can take an action.

1. **Insight triage weight.** Do this first after routing.
   - **Where.** [insight-triage.md](insight-triage.md). No code exists yet.
   - **Decision.** For each row the attention inbox lifted, a Noul "Should the owner open this row before the others?", or a three-level Score. The reason becomes a Choice over fixed reason words.
   - **Replaces.** The planned `triage` model role (that note's section 3.5) and its free-text `why` line (section 4.1).
   - **Why Jev.** The rerank cookbook has the same shape, with a sortable probability per candidate. A request takes about 0.2 s where a model request with a 400-token answer takes much longer, and costs about 2k input tokens.
   - **Risk.** A closed-set output removes the model-written `why` text that the note spends sections 4.2 and 4.3 containing. Rows include tool output, which is untrusted. The worst case is a wrong order, never an action.
   - **Measure.** The note's own plan (section 8): 30 sessions marked "open first" or "fine to skip", with a top-three hit rate against newest-first. Dismissals are further labels (`client/attention`).
2. **Advisor feed screen.** In shadow mode first.
   - **Where.** `client/advisor`, the `due` decision for a mid-run feed.
   - **Decision.** Nouls over the same 32 KiB slice the advisor reads (`advisorslice`): "Is the agent repeating failed steps?" and "Is it claiming completion without evidence?" When all are low, skip the mid-run feed.
   - **Sits beside.** The step counter (`feed_every_steps`, default 20).
   - **Why Jev.** This is the documented "screen with a Noul first" pattern, and each skipped feed saves an advisor-model turn.
   - **Risk.** The primary's own text is in the slice and can argue the screen down. Screen only the step-threshold feeds, never the run-end review or any goal completion.
   - **Measure.** Shadow mode needs no labels of its own. Every advisor verdict (Quiet against Nudge or Block, in `tools/advise`) is the label for the screen's value.
3. **Failure-taxonomy labelling for the evaluation instrument.**
   - **Where.** `docs/review/eval-failure-taxonomy-2026-10.md`. It is a protocol, and its results table is empty.
   - **Decision.** For each failed session, a Choice over the taxonomy's classes, plus Nouls per symptom.
   - **Why Jev.** It runs offline with no latency constraint, takes no action, and is named in Jev's use-case map as "Agent run review".
   - **Risk.** Transcripts leave the machine, so it needs the same opt-in as routing. The labels are opinions and must not feed `evalstat` verdicts.
   - **Measure.** The owner hand-labels 30 of the sample of 40 the protocol already draws, then compares agreement.
4. **Approval attention flag.** Shadow only.
   - **Where.** `client/escalate`. No risk classification exists today.
   - **Decision.** A four-level risk Score, plus a Noul "Is this call consistent with what the user asked?"
   - **Risk.** The arguments are written by the model that wants approval. The signal may only raise attention. It must never lower it and never approve.
   - **Measure.** The stored operator decisions are the labels.
   - Ranked lower because security is the first design priority.
5. **Goal completion second opinion.**
   - **Where.** `client/goalloop`.
   - **Decision.** A Noul "Does the check output show the goal's condition met?", which forces one more review when it disagrees with a `Complete`.
   - Worth trying only after item 2 has shadow data.
6. **Sub-agent and session profile choice.**
   - **Where.** `tools/agent` and `client/catalog`.
   - It would reuse routing's `agent` question and catalogue. Defer until an agent label exists, since nothing can measure it now.
7. **`history_search` reranking**, with a Noul per full-text hit. The rerank cookbook reports top-1 rising from 5 to 30 percent. It needs relevance labels that do not exist. Later.

## 5. Dismissed, with reasons

- **Gate strength and "addressing"** (`project/gate`): this is authority and must stay deterministic.
- **Compaction trigger** (`runtime/hooks`): token arithmetic is exact.
- **Repeat guard, malformed-call guard and vetting** (`repeat_guard`, the planner, `codemode/vet`): exact checks beat a probability.
- **Retry classification** (`provider/retry`): it would add a network call to an error path. Add patterns instead.
- **Hooks** (`client/hookdecisions`): a deterministic operator contract, and an operator's script can already call Jev.
- **A native `cap/jev` for code mode**: the MCP path already works, and the gain is one fewer child process.
- **Glance, summaries and titles**: free text, which Jev cannot write.
- **Stop-request and question-versus-task detection**: no such decision point exists in the code.

## 6. Recommendation

After routing, do the insight triage weight first, then the advisor feed screen in shadow mode, then failure-taxonomy labelling. All three have labels available or already planned, and none can take an action on a wrong answer. Each is its own design and its own review, and none is started by this note.
