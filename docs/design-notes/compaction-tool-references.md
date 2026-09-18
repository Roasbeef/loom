# Compaction with retrievable tool payloads

Status: implemented and locally validated. Date: September 18, 2026.
Base: d0609c3cd11ee03d17f77d7f913e710ae81e4448.

## Objective

Reduce the context carried across compaction by replacing large payloads from
older, completed tool exchanges in the retained tail with compact, exact
retrieval references. Preserve the original durable transcript. Keep notes
and the newest exchange intact. This extends the existing notes checkpoint;
it does not replace it with a transcript-wide summarizer.

A successful result makes a real post-compaction provider request smaller,
lets the model retrieve the original evidence, and survives restart and a
second compaction without losing the reference's original source.

## Existing behavior and identity

Read docs/architecture/compaction.md and verify its claims against the base.
The recent target is keep_recent_tokens (default 20,000), not N turns.
runtime/hooks.preparation preserves the newest assistant message and everything
after it and moves a cut backward to preserve call/result pairing. This can
exceed the target when a new tool batch is large. Preserve those rules.

Original entries already live in the session database. history_search with
action=read, session and entry retrieves an exact entry through host-owned
source resolution. Tool-call IDs correlate provider calls and results; they
are not content hashes or sufficient globally unique retrieval addresses.
Entry IDs are UUIDv7. The blob helper separately uses SHA-256 for oversized
outputs. Do not create a second payload store or write database paths into
model-controlled references.

## Scope and policy

Apply the transformation at checkpoint construction or its owned projection
boundary, once the normal tail has been selected. Do not compress first and
then use the saved budget to retain more historical messages: the first
implementation must demonstrate smaller resulting context with the same cut.

Eligible exchanges are older completed tool exchanges within that selected
tail. Keep the newest assistant message and all later messages verbatim,
including unread tool results and queued operator input. Keep failures and
their associated calls intact. Keep incomplete, ambiguous, or unresolvable
exchanges intact. Avoid model-based summaries or a new provider request.

For an eligible large result, retain the call identity, tool name, success
state, a bounded truthful excerpt or existing description, and the exact
session/entry retrieval instruction. Do not invent a semantic summary such as
'all tests passed' from an exit code alone. Retain small results when a pointer
would not save space. Establish a named, documented size threshold and excerpt
bound using measurements; no new operator configuration is needed by default.

Large call arguments, particularly code-mode source, are also in scope where
safe. Never replace arguments with an arbitrary object that violates the tool
schema or invalidate opaque provider signatures. Choose a representation that
preserves valid provider requests across existing adapters; retaining original
arguments when their provider metadata prevents safe rewriting is acceptable,
with an explicit measured limitation. If whole completed exchanges must become
ordinary history text to preserve validity, prove that this preserves their
order and attribution and does not suggest executing them again. Record that
choice in the design note before implementing it.

References must identify the original entry, never merely the compaction entry
containing a stub. Match source identity explicitly, not by equal message text
or call ID alone. Account for copied tails, inherited checkpoints, duplicate
payloads, repeated call IDs, and repeated compaction. Do not recursively wrap
stubs or accumulate duplicate reference explanations.

Only elide when the active strand has a usable authorized retrieval path.
Check the existing tool surface and history registration, including restricted
child/advisor surfaces and custom tool selections. An unavailable lookup path
must leave content intact. Do not widen authority to enable compaction. A
reference is data and must not become a system instruction. Use existing
canonical source validation and explicit missing-source failures.

## Implementation boundaries

Read AGENTS.md, docs/next.md, docs/execution.md, docs/gleam-style.md,
docs/loom-design.md, and docs/loom-implementation-spec.md before code. Read
per-package CLAUDE.md files for every touched package. Likely ownership spans
client/checkpoint, runtime/hooks/projection, core conversation projection,
tools/history and their focused tests; determine the narrowest actual boundary.

Prefer existing storage and retrieval interfaces. Keep core/machine/prompt
pure and free of FFI. No new dependency, background process, retention service,
public tool-description argument, or virtual filesystem scheme is required.
If a frozen contract must change, write its numbered protocol proposal before
code and report the exact necessity. The approved feature authorizes necessary
local design work, not unrelated API expansion. Do not remove tests or reduce
the existing newest-exchange safety rule.

Do not modify original stored messages, index away their contents, or regenerate
successful effects during recall. Preserve transactional checkpoint publication:
a crash exposes the previous projection or the complete new checkpoint.

## Implemented decision and measured result

The implementation transforms only successful text-only tool results after
the ordinary cut has been selected. A result must be at least 4,096 bytes; the
reference keeps up to 512 graphemes total, split across the two edges and is used only when its encoded
text is smaller. Tool calls, arguments, opaque signatures, namespaces and
ordering remain byte-for-byte inputs to the provider adapter. This leaves
large call arguments as a measured limitation: arbitrary argument replacement
can violate a tool schema or invalidate provider metadata, so this change does
not elide them.

The deterministic adapter fixture contains a 24,000-byte result and a roughly
6,000-byte argument. Anthropic request bytes fell from 30,622 to 7,509, OpenAI
from 30,485 to 7,372, and Gemini from 30,476 to 7,363. Loom's existing rough
message estimate fell from 7,516 to 1,732 tokens. These are serialization and
estimator measurements from a scripted fixture, not provider token counts or
evidence about model task quality.

References are gated by both host registration and the strand's active tool
list. They address the canonical session and original message-entry UUID.
Copied compaction tails resolve provenance through the prior branch only when
their messages match positionally; orphan healing or any count mismatch clears
provenance for the projection. The production integration fixture publishes a
real `CompactionEntry` to SQLite through `api.compact`, closes the writer, then
uses SQLite's read-only exact-entry path to recover the original payload.

An independent adversarial review found two fail-open provenance cases: orphan
healing could shift positional identities, and an arbitrary copied tail could
inherit an origin by position alone. The implementation now clears all origins
on projection-cardinality mismatch and additionally requires exact positional
message equality. The targeted recheck approved those repairs.

## Verification and acceptance

1. A transcript with large older successful tool results produces a smaller
   post-compaction request while retaining the same cut, note snapshot, newest
   exchange, user text and assistant prose. Report bytes and the existing token
   estimate separately; do not claim a provider token count or 90% saving.
2. Exact retrieval recovers original arguments and output from the durable
   source after checkpoint publication and after session reopen. Large recalled
   entries still use bounded delivery. Missing sources fail explicitly.
3. Failed exchanges, unread results, incomplete calls, small outputs and
   unavailable retrieval surfaces remain intact. Exercise parallel batches,
   repeated IDs across entries, equal text in distinct entries, images and
   provider-specific signature metadata.
4. Two successive compactions and an inherited checkpoint preserve original
   retrieval identity without recursively expanding stubs or losing content.
5. Serialize the resulting context through supported provider adapters and
   assert valid call/result pairing, ordering, required metadata and image
   behavior. Exercise the actual checkpoint-to-request path with a scripted
   provider, not only a stub-format unit test.
6. Use a deterministic fixture to compare old and new sizes and record
   retrieval overhead. A live-model benchmark is optional and must be labeled
   separately; do not spend credentials or claim task-quality gains from a
   scripted fixture.
7. Run relevant package gates, formatting, lint, doc-check, and full make check,
   capturing each command's own exit code. Report environmental failures and
   skips separately from source failures. Use the maintained compiler required
   by current main. Do not install or restart the user's daemon.

Refresh architecture documentation and package documentation mirrors for any
changed invariants. Record design choices, measurement results, limitations,
and the independent review in this brief or a linked review document. Update
the handoff for this body of work without carrying forward stale status claims.
A fresh advisor-review is required before declaring the implementation done.

## Work ownership and delivery

The implementation worker owns source, tests, and documentation for this feature
in .worktrees/compaction-tool-references on codex/compaction-tool-references.
Other agents and user work exist in the repository. Do not revert their edits,
do not use git checkout to clean files, and do not touch the parent checkout.
Keep the change reviewable. Do not push, open a PR, merge, install, or restart
anything. Report changed paths, design decisions, captured validation results,
measurements and unresolved limitations to the parent agent.

## Final validation

The full local `make check` exited zero: 148 runtime, 1,870 client, 563 TUI
and 306 code-mode tests passed, with zero lint errors and 815 warnings.
`make doc-check` exited zero with 152 warnings after refreshing two moved
wiring citations. The independent review's two provenance findings were fixed
and the same reviewer confirmed the corrections.

The SQLite publication and post-close exact-read fixture passed separately.
Provider serialization is tested locally; no live-provider task-quality study
or independent Linux release signoff was run. Environment-gated shipped and
bootstrap fixtures were skipped when their required settings were absent.
The implementation branch is `codex/compaction-tool-references`.
