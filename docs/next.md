# Current handoff

This edition records the October 10, 2026 CPU and memory investigation on
`codex/perf-text-hygiene`, based on `c66bd27264cd8b1350ed8309be2388d22fa0d195`.
The [resource profile](review/loom-resource-profile-2026-10-10.md) records live
Pickglass captures, bounded state/GC probes, and matched before/after results.
The installed daemon and clients were not replaced or restarted.

## Resource work and next steps

The pure `session_view/text_hygiene.multiline` fast path avoids codepoint-list
construction for clean text while preserving owned binary output. Live traces
found about 258 MB of sanitizer allocation in one browser window and 130 MB
in one terminal window, each about 15 seconds. The matched small browser
fixture saves 11% reductions and 79% sanitizer allocation. Those are allocation
and work measurements, not proof of permanent installed RSS savings.

Six focused tests and the exhaustive Unicode scalar differential passed.
The independent review found no actionable defect. The affected gate retry
finished red: session-view, browser and conformance passed; a separate terminal
gate passed with exit 0 and 1,281 tests after the combined lane stopped at the
client failure. Client had 3,222 passes and one modeled blob-jail
refusal failure at `client/workspace_test.gleam:900`. Focused runs with both
the candidate and saved unchanged sanitizer reproduce it. The initial attempt
passed static checks but could not fetch preparation dependencies under
network restrictions. Scope confirmation was requested before fixing this
separate boundary. The aggregate gate is not green.

Next: disposition the existing gate failure, then compare a reviewed release
under matched installed workloads. Retained job history, Lustre cache/model state, and
supervisor restart inputs are documented candidates for further measurement;
none was removed or trimmed. Stream-fragment copying was inactive in the
follow-up probe. The resource optimization goal remains active until installed
CPU and memory improvements have been verified.

The prior browser-work handoff follows as inherited context. Its remote CI
and merge claims have not been refreshed by this profiling task.

# Previous handoff: browser result work

This edition records the October 8, 2026 browser result work on
`fix/browser-tool-output`, originally based on `16c3c0ee5` and now integrated
with PR #927's readiness head `71887e1b7` and main `16f886bd0`. Claims were checked against
the implementation and the [browser report](review/browser-large-results-2026-10-08.md).
The primary checkout's unrelated files were preserved; work remains isolated
in `.worktrees/browser-tool-output`. The installed client and daemon were
not replaced or restarted.

## Where the tree is

| Work | Current evidence |
| --- | --- |
| Terminal large-result wrapping | PR #925 merged as `fa4e45f8b`; hosted CI and exact-head Linux signoff are green. |
| Code-mode/LSP readiness | PR #927 at `71887e1b7` is included here so both changes are tested together. Original head `d72948088` passed Linux signoff; fresh integrated-head CI/signoff are pending. |
| `fs_edit` empty hunks | PR #919 advertises `minItems: 1` on the hunk array; the decoder already refused empty edits. The final six-package affected gate passed in 295 seconds, and the independent review, including its follow-up on the prompt wording, found no actionable issue. The corrected prompt contracts restore two phrases that client assertions expect. Both ran before this rebase. |
| Browser complete-result access | Stable immutable-record URLs offer 16 KB pages and complete JSON attachments. |
| Browser local validation | Full affected gate returned exit 0 in 329 seconds; no undeclared skip. |
| Independent browser review | No HIGH/MEDIUM finding; two LOW cleanup findings applied. |

The previous handoff's instruction to publish the terminal PR is obsolete.
Its measured speed results remain in the [wrapping report](review/tui-large-result-wrap-2026-10-08.md).
Compile/export reuse PR #917 and Link-form PR #926 are already merged. The
Darwin-only declaration records two existing broker /proc prerequisites; no
tests or assertions changed, and both tests ran successfully on Linux. Issue #924 implementation
and its validation are recorded in PR #927's own branch and
[report](https://github.com/Roasbeef/loom/pull/927).

## What to do next

1. Finish PR #927's integrated-head CI and Linux signoff, then merge it as
   authorized. **Exit:** its exact published head is green.
2. Finish PR #928's integrated-head CI and Linux signoff, then merge it as
   authorized. **Exit:** its exact published head is green after #927 merges.
3. Install a reviewed release when the owner requests it. **Exit:** verify
   behavior in the resident client/daemon; disposable tests do not establish
   that the installed processes changed.

## Rulings already made

**Keep complete terminal output.** Measured grapheme cursors consume each code
row once. The terminal retains complete source and results; a small viewport
does not justify discarding their text.

**Make browser access explicit.** The normal transcript stays bounded.
Paging reads one storage fragment, and a download reads a complete bounded
record under one deadline. Both use existing page/session authority; entry
identity alone grants no additional read access. Protocol-change/079 records
this decision. No component-side result ledger is required.

**Preserve matching immutable identity.** A narrative join carries the identity
of the same result whose outcome it displays. An orphan result keeps its own
source identity. These are regression-tested in the browser lane.

**Separate proof scopes.** The preview bounds rendering and scanning, not all
BEAM backing-binary retention. The real HTTP tests use an explicit fixture
reader; the storage tests independently round-trip a real SQLite result.
The installed session was not modified to produce either result. Original-head
gates and signoff do not attest to a new integration head. Each merge must
check its own current SHA.

## Deliberately open

Search in the viewer applies to one page, and byte windows can split JSON
syntax or lines. The full attachment is the complete stored record. Output
summarization, whole-result browser search and installed-process replacement
are outside this PR. No new FFI, dependency, process machinery or sandbox
privilege was introduced.

## How to verify

The [browser report](review/browser-large-results-2026-10-08.md) records commands,
test counts, review scope and limits. Run `make gen-client` after changing
browser source, then `make check-affected BASE=16c3c0ee5` and required Linux
signoff on the pushed clean head. Judge every gate by its own exit code.
Keep code-mode worktrees outside `/tmp` and follow [execution](execution.md)
for the remaining verification rules.
