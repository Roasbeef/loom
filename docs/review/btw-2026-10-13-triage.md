# Side-query review triage, October 13, 2026

Three adversarial lenses examined PR #981 from `dc70d25d4` through the initial
`04dd10575` head. Separate triage verified each claim against production callers
before repair. Round two examined the repairs and found one additional width
mismatch. Round three and its separate triage are clean at the medium cutoff.
Three fresh cold reviewers approve the service/runtime, shared UI and
provider/protocol slices at `69d4d6461`; their reports sit beside this record.

**All four confirmed medium findings are fixed; cold acceptance approves the
reviewed source.** This verdict does not claim final-head CI or strict Linux
signoff has completed, or that a live Anthropic cache hit was measured.

## Disposition

| ID | Reachable claim | Disposition | Repair |
|---|---|---|---|
| ISO-001 | A delivered account can contain lost drain proof; erasing the typed outcome releases capacity while a transport may remain live. | FIX | `7c96483dc`: retain typed outcomes and service-lifetime uncertain reservations, with real HTTP owner-loss and clean reuse coverage. |
| UI-CACHE-001 | A busy lane cannot perform a side read but can repeatedly arm an already-expired browser deadline. | FIX | `348a7e113`: expose the side deadline only for the matching attachment's readable lane. |
| UI-CACHE-002 | Painting splits the TUI transcript while scroll, image and copy consumers use the full rectangle. | FIX | `69d4d6461`: share reading rectangles, separate side copy from main gutters, regress wheel/clipboard/image paths. |
| UI-CACHE-004 | Side paging counts rows at terminal width while the docked rail narrows painting, making a long answer's tail unreachable. | FIX | `69d4d6461`: wrap at the actual transcript width; rendered tail regressions cover shown and hidden rails. |
| DOC-01 | The v2 protocol reference omits the new command and snapshot mode. | DOC | Document command fields, operator scope, board and lifecycle; add `btw` to the auxiliary snapshot lists. |
| UI-CACHE-003 and cold UI observations | Refresh can retain old scroll; side wheel routes to main; side keys precede help/notes. | DEFER | Low UX follow-up [#983](https://github.com/Roasbeef/loom/issues/983); approval dialogs remain earlier in dispatch. |
| COR-I01 | Effective observer capture and actual cross-provider fallback lack a direct combined production-path regression. | DEFER | Coverage improvement [#984](https://github.com/Roasbeef/loom/issues/984); source trace preserves settled fallback identity and effective context. |

Speculative cross-service ambiguity was dismissed: catalogue keys distinguish
provider entries, and resolved side routes have one attempt. Tools remain in the
request for cache reuse but no side executor exists. Main and side histories,
usage settlement, observer authorization and reconnect ownership were checked
without finding another reachable medium defect.

## Personal E2E

The primary reviewer operated the real TUI in an isolated tmux server and the
real daemon web UI through an isolated browser, backed by a local OpenAI SSE
fixture rather than paid model calls. Both attachments asked private questions
while the main response streamed. Raw provider requests show old frozen context
on TUI follow-ups after main advanced, and newer context only after web refresh.
Overlap produced no provider request. Cancellation closed the side HTTP stream
while main output kept advancing and the unsent web draft remained intact.

A generated call to advertised bash was refused: one inference request, no
continuation, no filesystem marker. At that checkpoint the session database had
six durable entries, all main questions/answers, with no side query markers.
Rebuilt-source tests reached a 15 KB answer's tail with the docked rail and the
oldest main rows with the mouse wheel while the side panel stayed open. A real
mouse drag emits OSC52 `LONG_START`, preserving the side answer's leading text. New
attachments forget private side history, and Clear/Close preserve the web draft.
An accidental long paste was correctly submitted as ordinary main attachment
input; the final paging case uses a short typed `/btw LONG_SIDE` command and a
long provider answer. This fixture action is not a side-to-main history leak.

Evidence is retained outside tracked source under the ignored
`build/pr981-personal-e2e/` directory and `/private/tmp/loom-pr981-review/`.
Focused checks passed: 6 side-service tests, 486 shared session-view tests, 8 TUI
side tests, selection and image regressions, formatting, lint and repaired doc
citations. The full affected run and final-head CI/signoff are recorded in the
handoff once settled. Live Anthropic cache economics remain deferred until the
owner configures credits.
