# 045: Catalogue-backed skill-selection hooks

Status: proposed with implementation. Extends the extension hook vocabulary in
protocol-change/012; no runtime operation or durable conversation schema changes.

## Problem and alternatives

The main model can call `load_skill`, but an installed extension cannot propose
known skill instructions without filesystem access or fabricating a context
message. A catalogue/read capability would give selectors more access than this
use case needs. Putting Jev in provider wiring would bind a generic harness to
one relevance service. A dummy tool would make a hook-only extension installable
at the cost of irrelevant model-visible surface.

## Decision

Admit `select_skills` and allow a manifest with at least one tool **or** hook.
An entirely empty extension remains invalid. Installation approval still covers
the declared hooks and egress policy; existing installs gain no subscription.

The hook runs after ordinary context transforms before every provider request.
Arguments are JSON text in the existing hook-call envelope:

```json
{"op_id":"...","messages":[],"candidates":[{"name":"review","description":"...","excerpt":"..."}]}
```

Messages use the existing core codec. Candidates come from the captured session
catalogue: only `ModelSelectable`, at most the first 64 in catalogue order, no
paths, and at most 512 graphemes of body preview. Descriptions retain their
existing discovery bound. All selectors receive the same pre-selection context.

The SDK exposes `OnSelectSkills(fn(SkillContext) -> List(SkillCandidate))`.
Candidates are opaque and only issued by argument decoding. The result is:

```json
{"skills":["review"]}
```

At most three string names are accepted per proposal. The harness resolves every
name against exactly the advertised catalogue and rechecks model eligibility.
It expands the known captured document with empty arguments and appends an
attributed user-message-shaped instruction. No returned document text, path,
arguments, executable effects or permissions are accepted.

One projection admits at most three distinct skills and 8,000 estimated tokens
including attribution across all selectors. Duplicates are idempotent. Any
invalid member or budget overflow discards the entire proposal, preserving
previous selections. The existing five-second deadline, failure logging and
satellite lifecycle apply. No candidates means no invocation.

These messages are transient provider input. They are not operator utterances
or new durable transcript entries. A later projection independently repeats
selection; an extension may cache its policy decision in existing scoped memory.

## Cost and compatibility

Old manifests remain valid. Old hosts reject the new event explicitly; an
extension cannot quietly run without selection. A selector may disclose its
context under its approved egress policy, just as a context hook already can;
the bundled extension deliberately sends a narrower task excerpt.

The separate skill budget can increase projected context beyond the ordinary
context-transform allowance. It is bounded, estimated rather than tokenizer
exact, and does not guarantee that a model's remaining context window fits.
Oversized full documents are refused rather than silently cut. Large catalogues
need a future paging or search proposal if the first-64 policy proves inadequate.
