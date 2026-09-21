# Design note: relevance decisions as extensions

Status: **built on the proposal branch; merge pending.** The skill-selection
slice is implemented; validation is recorded in the PR. The broader ideas below are
experiments, not committed work. Baseline: `a216d837` (2026-09-21).

## Source and thesis

This note distills founder notes supplied by the operator from TypeSafe/Jev,
then develops their implications for Loom. It paraphrases the supplied text;
the proposed experiments and enforcement boundaries are our interpretation.
Claims about other agents, provider economics and model quality are hypotheses
unless measured here.

The central idea is to make context selection an explicit operation. A coding
agent's loop is small; much of its cost comes from deciding what to read,
carrying material forward, and transferring it between tasks. Cheap structured
judgments could select relevant instructions, tools or evidence before an
expensive generation. Selection must earn its latency and inference cost.

The useful counterfactual is: how would we build an agent without a KV cache?
We would probably retrieve task-specific state more often instead of maintaining
one ever-growing transcript. Actual systems have caches, so the engineering
question is when fresh selection beats retaining a reusable prefix.

## What the existing tree already does

Loom discovers immutable skill documents and advertises model-selectable names
through `load_skill`. The prompt tells the agent to load relevant skills. That
is proactive use by the main model, but there is no independent relevance pass.
User invocation and model invocation are separate flags: hiding a slash command
does not disable automatic selection, and `disable-model-invocation` does.

Extensions already execute in a jailed satellite with brokered HTTP and their
own durable memory. Context hooks transform transient provider input. This is a
natural place for optional relevance policy; no Jev provider belongs in Loom's
core, machine or provider packages.

## Decision 1: select documents, do not invent instructions

Add a generic `select_skills` hook. The harness sends the projected messages and
up to 64 eligible name/description/512-grapheme previews. The SDK issues opaque
candidate values. A typed extension can return those candidates; the host still
validates every untrusted wire name against exactly the advertised catalogue.
Loom expands the captured document with empty arguments, attributes its source,
and injects it after ordinary context transforms. It never executes a skill's
scripts and never grants a permission because a skill requested it.

At most three skills share an 8,000 estimated-token allowance across all
selectors. Repeated names are idempotent. A malformed, unknown, oversized or
failed proposal contributes nothing; previous selectors remain intact. The
existing five-second hook deadline applies. Full instructions are not truncated
to fit. Skills beyond the first 64 remain available through ordinary load_skill
and explicit invocation. This bound is a first-release limitation to measure.

This API is deliberately narrower than adding filesystem or catalogue-reading
capabilities. The selection use case needs previews and a load proposal, not
arbitrary path access. Protocol 045 specifies the contract.

## Decision 2: keep Jev policy in a separate extension

`roasbeef/loom-skill-selector` uses `roasbeef/jevelin`, the transport-independent
Gleam API client. One batched Noul question per candidate asks whether its
instructions directly help the task. Scores at or above 0.85 qualify; the three
highest are returned. This threshold is a heuristic, not a calibrated guarantee.
Independent questions allow complementary skills and an all-negative answer.

The extension filters the known native note, memory and imported-hook wrappers
before extracting task text. This is policy over projected messages, not a
provenance boundary: other installed context transforms can rewrite messages.

The request contains only the latest remaining user text (bounded to its last 4,096
graphemes) and candidate previews. It excludes tool outputs, assistant text and
older conversation from the external request. Installing the extension permits
this disclosure to the declared TypeSafe origin. The broker injects credentials;
the satellite never reads them. A single cache cell binds a decision to the
operation, exact task and previews. Replaying a projection restores the selected
instructions; it does not append another durable transcript entry. A changed
operation or task causes fresh selection. Failures cache an empty selection for
that identity to avoid repeated failed calls. Oversized cache records can miss.

The installer now admits hook-only extensions. Requiring a dummy model tool
would inflate the very tool catalogue this feature is intended to improve.

The installer builds offline from a frozen capability surface. The extension
therefore vendors the pure Jevelin source at a pinned public commit, with a
reproducible verification script. This adds neither a provider-specific harness
dependency nor a general dependency-download capability to the jail.

## Cache-aware routing: an illustrative calculation

The founder supplied historical hypothetical prices of 5/25 for a larger
model and 3/15 for a smaller model, in dollars per million input/output tokens.
These are not current pricing claims. Let X be the existing context, Y the
output generated during a delegated segment, and Z additional tool content,
all in millions of tokens. Under the supplied assumptions, the incremental
cost of staying with the large model is `25Y + 5Z`. Switching to the smaller
model and then back costs `3X + 20Y + 8Z`.

Switching saves money only when `5Y > 3X + 3Z`. With X=0.65, Y=0.12 and
Z=0.23, the costs are 4.15 and 6.19: staying costs about 67% as much. This
explains a plausible failure of naive model routing, not a universal result.
Cache-read/write prices, residency, reused prefixes, repeated turns, reasoning
tokens, latency and output quality all need measurement in a real comparison.

## Experiments that follow from the thesis

| Idea from the notes | Loom experiment | Evidence needed before adoption |
| --- | --- | --- |
| Tool and skill disclosure in stages | Select previews, load full instructions or schemas only when needed | Relevant-use recall, false activations, schema tokens and end-to-end task success |
| Query-aware context rather than one shared summary | Classify chunks as omit, summary or full, preserving provenance | Critical-evidence retention, cache loss, selector cost and downstream errors |
| Conditional AGENTS guidance | Select optional guidance by task and subtree | Mandatory policy always retained; scoped guidance survives projection changes |
| Explicit state for delegation | Construct a versioned evidence packet for a bounded task | Retrieval cost, missing facts, merge cost and total completion time |
| Retrieval on restart | Reconstruct relevant state from durable sources | Same task continuity without silently changing accepted decisions |
| Semantic filtering of search output | Keep referenced evidence with a tunable relevance threshold | False-negative rate on required matches and ability to recover omitted text |
| Read-only background work | Share one immutable code/evidence snapshot across review, explanation and eval generation | Snapshot identity, cancelled stale work, findings per dollar and user distraction |
| Structured skills | Let operator-installed extensions supply hooks associated with workflows | Explicit lifecycle, isolation and permission ownership; Markdown cannot install hooks |
| Subgoal deduplication | Compare proposed work with completed and active subgoals | No suppression of necessary retries or distinct goals with similar wording |
| Data-sensitive routing | Rank within a deterministically permitted provider set | Classification never broadens egress policy or authorizes sensitive disclosure |

The source also mentions recursive language models, structural search and
context-compression tools as possible components. Their individual performance
claims are unverified here. We should evaluate task outcomes rather than adopt
tools because a token count or search benchmark alone looks favorable.

## Acceptance and evaluation

The implemented slice must prove that an ordinary user task can cause the real
jailed extension to make brokered HTTP, return known skills, and place their
full instructions in the next provider projection without a manual invocation.
Tests must also cover no selection, malformed/outage answers, unknown and
explicit-only names, aggregate limits, deduplication and repeated projections.
A synthetic Jev endpoint proves plumbing, not relevance quality or live service
compatibility. Authenticated Jev evaluation is a separately reported check.

For quality, start with labelled examples containing both positive tasks and
near misses: asking to implement a UI versus quoting a UI skill, asking for a
review versus describing a past review, and explicit-only deployment skills.
Compare the current prompt-only baseline against the extension on selection
recall, false activations, added tokens, inference cost, p50/p95 latency and task
success. Keep the extension opt-in until the gains exceed its overhead.
