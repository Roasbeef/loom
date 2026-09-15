# Model selection when spawning a child

Status: accepted and implemented for the requested per-spawn model selection.
Affects the `agent_spawn` tool and the `strand.spawn` capability argument map.

## Problem

A parent can choose a child's brief and tools, but cannot choose its model.
Every child takes the configured `subagent` route, or inherits its parent when
that route is absent. A reviewer spawned this way may therefore use a different
model from the one the user requested, with no model identity in its receipt.

## Decision

`agent_spawn` accepts an optional `model` string naming an entry in the host's
model catalogue. The tool schema advertises the selectable catalogue names.
An explicit name selects that entry's model identity and initial thinking
level. An unknown name is an in-band invalid-argument refusal before creating
a strand. Omission retains the existing subagent-route and parent-inheritance
behavior. It does not change the parent's configuration or widen child tools.

The selected identity is stored in the child's existing `StrandConfig` before
its brief runs. Recovery adopts that durable configuration without resolving
the requested name again, so a changed catalogue cannot redirect an admitted
child. The `agent_spawn` receipt adds `model` (the configured catalogue name)
and `model_id` (the configured provider model identifier). These describe the
child's configuration at observation time, not a claim about provider execution
or a promise that an operator will never change its configuration later.
The existing role-fallback chains and vision routing remain applicable; choosing
a model at spawn does not introduce a new per-request routing policy.

`cap/strand.with_model(assignment, name)` carries the same optional `model` key
on `strand.spawn`; absent or nil retains the old behavior. The existing handle
result is unchanged. No durable codec or framing-version change is needed.

## Alternatives and cost

Putting a model name only in the brief cannot enforce model selection. Passing
an arbitrary provider URL or model identifier would bypass the host's configured
catalogue. A separate model-switch command after spawning would race the child's
first request. Selecting at creation reuses the durable configuration boundary
and costs one catalogue lookup, plus a configuration read for the tool receipt.

## Validation

The affected package gates pass: tools (450 tests), cap (84), codemode (302),
and client (1,797). They cover tool decoding and model-name advertisement,
catalogue selection and seed thinking, refusal without a child, unchanged
defaults and parent configuration, both recovery paths after catalogue changes,
and code-mode encoding and decoding. The production-assembly fixture exercises
the assembled tool, runtime, gateway, and provider adapter and checks the actual
outgoing model ID and thinking budget using a scripted transport.

An isolated mutation replacing the requested model with omission fails the
first-request regression at the model-identity assertion: the default model
reaches dispatch instead of the selected reviewer. Format, documentation,
prelude, and affected-package lint checks pass. Existing lint and documentation
warnings remain outside this change.
`make e2e-codemode` also passes all 302 tests after rebuilding the offline seed,
including the real jailed build and the orchestration sample. This macOS host
cannot perform the seed script's separate Linux-network-namespace probe; the
jailed end-to-end tests execute rather than skipping.

Independent adversarial review found no actionable defect after tracing initial
selection, both adoption paths, receipt accuracy, and code-mode compatibility.
Its disposition was to retain the existing role fallback and vision behavior
and document that a receipt describes configured identity. No live external
model request or Linux signoff was run for this change.
