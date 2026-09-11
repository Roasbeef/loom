# Developer experience polish: acceptance ledger

Base: `3ce454e6`. Candidate: `codex/ux-polish`. The September 10 consolidated
video/database review supplies the criteria. The operator additionally requires
clear user/agent attribution and a generalized permissive default with explicit
lockdown controls.

## Implemented behavior and local evidence

| Area | Result and evidence |
|---|---|
| Development policy | Host reads and shell network default; workspace writes, protected masks, and independent read/network restrictions remain. Language-manager admission lists are gone. Real helper fixtures cover native search, Git, Python, Go+cgo, cache writes, failed-pipeline status, outside-write refusal, and restricted outside-read refusal. The installed run also verified authenticated read-only GitHub and code-mode batching without per-command environment repair. |
| Roles and reasoning | Explicit user, agent, and reasoning labels; shaded user messages and full retained reasoning independent of tool expansion. Native history capture shows the original prompt and agent response with the wide diff still visible. |
| Diff | Automatic wide pane, retained explicit dismissal, narrow fallback, independent patch scrolling and file navigation, composer focus, and a refresh retained behind in-flight observation. Real-Git tests exclude untracked Loom caches while retaining deliberately tracked contents. Native captures show the initial empty pane, then three changed files and live patch contents. |
| Current state and queue | Previous-operation labels distinguish an earlier result from a live successor. The turn timer resets on successor identity. Unsent, sent, and received input remain distinct. The installed run passed receipt, reconnect with pending input, queued successor, and Steer ahead of ordinary queued work. |
| Notes and completion | Structured notes render as Markdown with raw inspection available. Notes distinguish overtaken reads and values predating the current turn. Completion leads with the designated final answer, includes successful file writes, and separates turn file-tool totals from workspace Git totals. Regressions count complete patches and edits beyond the 32 displayed outcomes. Missing history remains explicitly partial. |
| Usage and jobs | Estimated cost has two decimals and cumulative totals are labelled. Completion distinguishes last-request context including cache from cumulative billable counts. The installed summary shows 610 input-context tokens and 70 output tokens, without adding reasoning twice, and distinguishes a completed operation from its remaining background sleep. |
| History and selection | A 600-entry/16 MiB payload cache fetches 100-position older pages independently of live metadata. Identity anchors preserve reading position. Fixtures traverse 1,200 entries, sparse reviewer ancestry, repeated calls, and a page larger than eight MiB. The installed run paged back to the initial request while two reviewers streamed. Native mouse press/drag/release was recorded; selected transcript rows and reverse highlighting survived incoming output and a detail toggle. |
| Provider and reviewers | Stopped reviewers return labelled saved partial observations. Persistent reviewer rows retain task/progress/receipt identity. Protocol 028 records bounded local initiators, request identity, attempts, and timeout/grace bounds through cleanup. Durable runtime fixtures preserve these diagnostics and Retry-After. The installed 429 fixture waited 1.057 seconds for a one-second hint before retrying. Unconfirmed cleanup remains terminal. |
| Tool recovery | Non-login Bash preserves PATH and pipefail preserves the failed command's status. Native search receives PATH without shell credentials. Query and handle-array examples match their schemas. Code-mode failures retain bounded assertion values and source context. The installed batch completed file read, write, and process execution in one program; a separate missing-file assertion exposed its actual `not_found` cause. Existing stale-anchor tests still reject stale edits and preserve the file. |
| Deletion | Stop, positive retirement observation, then one delete. Unknown outcomes and unconfirmed drain preserve registration. The installed fixture deleted only its disposable resident session, including retirement of its background shell. |

## Verification

One uninterrupted `make check` returned exit 0 on the final implementation:
4,191 Gleam tests across twenty packages, native helper checks, prelude
verification, and house-rule lint. This includes 1,541 client, 342 TUI, 206
provider, 129 runtime, 86 machine, 350 tools, 67 cap, and 280 code-mode tests.
Lint reported zero errors and 666 advisory warnings. Real code-mode prerequisites
were prepared; existing platform-specific and opt-in shipment checks retain
their own prerequisites rather than becoming implicit Linux acceptance.

The isolated self-contained installation was rebuilt after that gate. Native
run `p82492` passed all nineteen scripted stages with two reviewers, retry,
actual tool results, selection, history, width changes, queue/steer, reconnect,
summary, and deletion. Its terminal recordings, captured screens, synthetic
provider requests, and matching SQLite backup are retained locally under the
repository's ignored `build/p82492` directory. These are deterministic local
provider fixtures, not an external-model quality or reliability benchmark.

The [independent review](ux-polish-review.md) and bounded follow-up have no
remaining confirmed production findings. The [resource report](ux-polish-resources.md)
records matched installed measurements and replay retention separately.

The candidate remains local and unpublished. The owner's existing daemon and
session were not restarted or modified. Hosted CI and Linux signoff have not
run on these commits; their successful base results are not candidate results.
