# 068: governed runtime evolution

**Status:** Accepted for implementation on 2026-10-04, within the owner's authorization to implement #807 in one end-to-end PR. Independent pre-implementation review resolved the ownership, model-selection and native-retirement boundaries below. The production implementation is in [PR #824](https://github.com/Roasbeef/loom/pull/824); its exact-head checks carry the release-verification verdicts.

## Problem

An installed extension is captured when a session is assembled. Its tool definitions, execution callbacks and hook bus are separate immutable values. Replacing one of them would allow a model to see a schema belonging to one version while invoking another. Prompt packs have a similar boundary: one session system string is assembled before the provider gateway resolves fallback or vision models.

Issue #807 requires an agent-authored extension to pass jailed tests that produce durable evidence, receive operator approval, serve new behaviour in the same running session, and roll back without losing the conversation or leaking workers. It also carries named executable skills and model-specific prompt evolution. The older resident-loader proposal does not establish those workflows and conflicts with Rule Zero for model-influenced code.

## What was considered

A native registry replacement would need coordinated changes to execution, clearance declarations, replay policy, provider advertising and hooks, plus an admission fence covering every strand and admission source. Updating the tool holder alone cannot provide that property.

A stable catalogue and invocation surface allows the new extension's typed declarations to travel as data, while its implementation remains in a jailed satellite. That keeps the existing native registry intact and makes the callable version explicit. A dedicated promoted-generation broker/executor pool can reuse the current orderly-retirement witness; using the extension's existing stop report would hide uncertainty about native cleanup.

Model-profile selection by the initiating model was rejected because the same request can later reach a fallback or vision model. A pinned profile map applied after actual resolution preserves exact model scope without adding arbitrary provider options to `ProviderRequest`.

## Decision

### Immutable candidates and evidence

A candidate is a bounded immutable source/text envelope. Its SHA-256 identity covers the artifact kind, callable contract, source and schema bytes, author-owned tests and fixtures, declared authority and relevant build/seam/evaluator identity. An authored path is provenance, not authority. The harness authorizes and captures the path once, then builds and evaluates only the captured bytes.

The candidate test entry is separate from the installed extension manifest. Every executable test module is vetted against the extension seam and compiled offline into the jailed evaluator. Legacy installed-source pruning is unchanged. Test claims and harness-owned observations remain distinguishable; incomplete evaluations are inconclusive.

Approval binds the exact candidate and evidence. Editing a covered input produces a new identity. Current compatibility is checked before approval and adoption. Author-controlled actor, scope and approval fields cannot grant authority.

### Durable catalogue ownership

A shared `<state>/evolution/evolution.db` uses the existing session storage schema and fenced writer lease. Each short mutation atomically appends a lifecycle entry and updates its reserved facts under sequence expectations. The lease and storage process retirement witness are released before compilation, execution or model evaluation.

The central catalogue is authoritative for approval, revocation and selection. A selection transaction MUST compare the current approval/revocation sequence and the previous selection generation. Comparing only a candidate identity is insufficient because rollback can select an earlier identity again.

A live session records an idempotent adoption audit referencing the central transition. These commits are not atomic across databases. Recovery completes a missing audit and revalidates approval before publishing the recovered generation.

The catalogue, its sidecars and immutable artifacts are protected from agent native filesystem tools and from every jail. Reads check provenance visibility. Global skill and model-profile selection requires daemon owner authority; a session operator can authorize only their granted session scope. Model-facing proposal, evaluation, inspection and invocation surfaces carry no approval, activation or revocation authority.

### Live extension boundary

Promoted tools are discovered through a stable catalogue and called through a stable generic invocation surface. A catalogue item includes the exact candidate identity and live generation, callable name, description and schema. Invocation MUST name that identity and generation. A stale token is refused rather than interpreted under a replacement schema.

One generation owner serializes activation against promoted invocations and complete promoted hook folds. A captured generation binds implementation, manifest, policy and callable contract together. Hook phases that govern one invocation retain the same capture through its before-tool, tool and after-tool sequence. An already rendered provider request retains its original bytes.

Installed native tools keep their existing registrations. Promoted discovery adds new callable behaviour without adding a provider-native function name on each activation. Documentation and tests must distinguish these two surfaces.

Ephemeral extension state resets on replacement or rollback. Durable extension data is version-scoped. No automatic state migration is introduced. Rollback affects future calls and does not undo external effects already performed.

### Native retirement

A stop acknowledgement, enforcement report, BEAM owner exit or `CallExited` is not sufficient evidence that all native resources have retired. The helper emits its execution exit before final cgroup removal; orderly helper shutdown joins that cleanup.

A promoted generation therefore owns a dedicated bounded broker/executor pool. Replacement publication waits for that pool's orderly native retirement verdict. Unconfirmed retirement retains custody, returns a named failure and prevents another generation from accumulating. The active and staging/retiring generation count is bounded.

Queued transition requests carry identity and a finite admission expiry, at most 120 seconds. The gateway returns a queued receipt within its existing six-second response window. Expiry is checked before central selection CAS. Once that irreversible commit succeeds, audit/publication recovery finishes independently of the original wait deadline. A caller that loses an acknowledgement inspects the durable request identity; a committed receipt takes precedence over a timed-out queue wait. Uncommitted expired requests cannot begin a later selection.

### Exact model profiles

A new session pins an immutable map of approved profiles keyed by exact provider, model and API identity. A resumed session retains its pinned map. Each provider attempt applies the matching profile after actual target resolution and starts from the unchanged base request, so fallback overlays cannot accumulate or cross model boundaries.

Description changes affect prose only. Registered names, argument schemas, replay policy, requirements and generated capability signatures remain authoritative. Attempt observations identify the selected profile and composed prompt/description digest, including failed fallback attempts. Task-template selection has an explicit application point and provenance.

Evaluation compares one candidate with a baseline on versioned tasks using isolated production runtimes, exact resolved targets, real tool execution and independent correctness checks. Limits apply to admission, wall time, turns, output, usage and cost. Partial evidence cannot establish improvement. Scripted fixtures establish lifecycle correctness; live model evaluation is reported separately.

Trace excerpts are bounded, attributed to actual model identities, joined to usage and operator-owned outcomes, and scrubbed before being passed to a jailed optimizer. Missing outcome remains unmarked. The scrubber's limits are documented; it is not a proof that arbitrary transcript text contains no secrets.

## Interface impact

The client/control surface gains authenticated evolution inspection and operator transition operations. Their total decoders must distinguish read authority, session mutation authority and global owner authority. Model-facing tools expose only the proposal/evaluation/discovery/invocation subset.

The provider gateway gains immutable profile-selection configuration and an attempt-observation callback. The frozen request vocabulary, tool execution contracts, entry types, storage schema and effect-plane framing do not change. Reserved facts and registered custom lifecycle entries use their existing extension points.

Commands are `catalogue`, `inspect`, `evidence`, `status`, `approve`, `revoke`, `select`, `rollback`, `admit_tasks` and `mark_outcome`. Payloads and bounded receipts are recorded alongside the implemented total decoders and in the client protocol reference. They must preserve the authority and version checks above.

## What it costs

Promoted generations add a bounded broker/executor pool and jailed satellites. Replacement and rollback wait for native cleanup and may return a busy or unconfirmed-retirement result. Catalogue reads and operator approval add durable short transactions; competing catalogue writers receive a named refusal.

The generic tool surface requires explicit discovery and version-qualified invocation. It avoids native schema replacement and its session-wide admission fence. Model-specific prompt maps retain bounded composed text for the session lifetime. Their selection and cache effects require measurement.

Resident loading, dependency downloads, family-wide model inference, optimization search and automatic state migration remain outside this implementation. Agent-authored source continues to run in a jail, and core changes continue through reviewed PRs and releases.

## Verification required

The primary fixture exercises agent authoring, real jailed tests, durable evidence, explicit operator approval, same-session version 2 behaviour, rollback to version 1, conversation continuation and worker cleanup across repeated cycles.

Adversarial fixtures cover stale catalogue tokens, changed candidate bytes, revocation racing selection, an invocation blocked during activation, a hook fold paused across phases, withheld native retirement, cancellation/expiry, corruption and recovery between central selection and session audit. Provider fixtures force model A to fall back to model B and inspect actual requests for profile isolation. Full repository and platform signoff remain required.
