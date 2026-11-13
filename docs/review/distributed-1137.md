# Distributed runtime acceptance

Issue [1137](https://github.com/Roasbeef/loom/issues/1137) tracks repository
handoff, placement, movement and page parity. The owner selected the Depth
workflow on October 29, 2026: an always-on trusted brain or gateway may hold
provider keys, while remote executors remain keyless. A gateway on a sleeping
laptop cannot provide close-lid progress.

## Device sign-in command

Source baseline: `4beaa6d96`. A signed-out page at a listed origin emits
`loom ui --device`, but the copy component rejected that literal and rendered an
empty shadow root. The grammar now admits that exact command beside `loom ui`;
the bounded session form and other subjects are unchanged.

The new positive regression fails with the old production line. A primary
verification restored only that line, ran `scripts/web_client_test.sh`, and
observed exit 1 with the device test failing and the other 317 tests passing.
After restoring the fix, the same suite exits 0 with 318 passing tests; the
reconnect transport check also passes. Added negative cases refuse whitespace,
extra flags, shell separators and command substitution.

The old committed bundle reproduces an empty copy component in Chromium. The
rebuilt bundle renders the exact command and its button at 375 by 812. A real
button click against a recording clipboard API makes one write of
`loom ui --device` and draws `Command copied`. That proves the component's call
to the clipboard API, not a write to the operating system clipboard. The fixture
uses the markup emitted by the root page; `page_test` separately checks that
markup. It does not exercise remote enrollment or device authentication.

`make gen-client` regenerated the bundle and stylesheet. Independent review
found no actionable issues and verified the generated hashes; the stylesheet
body is unchanged. The Linux gate and strict census passed. Local affected validation remains red:
its four-way client rerun passed 5,474 tests and other lanes but failed census on
three evolution skips because the runner omitted the opt-in used by CI. The
separate real evolution target passes all six tests with no skips. Hosted CI
finished cancelled after a macOS shard exceeded its 50-minute job budget; another
advisory shard's raw log has two failures despite its badge. Their causes remain
unclassified after three isolated local passes each. Exact receipts belong on
PR #1143. No live daemon was restarted or deployed.


## Honest distributed observations

Source baseline: `2f917ae21`. A refused remote stub now projects its bounded
reason ahead of an older progress glance. The web card draws remote failed-row
activity as escaped text; local failure labels keep their existing wording.
Sender and receiver record fixed refusal classes and call-site coordinates,
without free-form reasons, briefs, model choices or tool lists. Retryable
`NotYetOpen` replies are not logged as final refusals. The 090 addendum records
the unchanged wire shape and transcript policy.

A primary check rendered the actual component from a controlled snapshot using
its ordinary decoder and reducer. In Chromium, opening the existing Settled
group exposes the refusal as literal text, including the test's `<script>`
characters; the DOM contains zero script elements. The terminal control was
removed. This is a component rendering check, not live TLS delivery or the full
server-component connection. The fixture browser and loopback server were
retired after capture.

The relay no longer infers an older build or a known absent effect from port
death. A recipient can accept a stop before the port dies; that recipient is
independent of the linked port worker, which dies with the port. Resends retain
uncertainty across later failed dials or refusals, and an unreadable send landing
also leaves delivery unknown. First-attempt pre-dispatch failures retain their
specific outcome. Existing identities and retry budgets are retained; no new retry loop is added.

Primary verification substituted the baseline production relay while retaining
the new tests: 21 passed and six regressions failed, including the accepted-stop
and unreadable-landing witnesses. Fixed source was restored in a `finally` block.
These witnesses record one effect in an independent modeled recipient; they do
not prove a persisted session mutation across a VM restart.

Read failures now use read-specific words. Failed creation and approval preflight
send no action. A failed listing or history refresh keeps the last complete row
and transcript with their observation time. A failed first read draws the refresh
error without a simultaneous loading claim. Failed, crashed and timed-out
resident overviews refuse the listing rather than creating false idle rows;
saved sessions and unfinished reservations remain listable. Resident resolution
uses its observed incarnation. The 094 addendum records these corrections.

The primary independently ran 489 focused tests across remote children, both
refusal diagnostics, relay outcomes, page adapters, resident overview behavior,
shared card formatting and actual page rendering; all pass. Implementation
witnesses also failed against the old projection, old formatter and each old
read path. Capturing tests reject both warning-to-debug diagnostic mutations.
Additional regressions use the actual SQLite writer and gateway: a decision
commits before an unreadable record or after the unchanged four-second reply
deadline, and its caller must retain uncertainty. The primary restored the old
read-back refusal as a semantic mutation, observed its intended failure after
the persisted-row assertion, and restored the typed result. Actual registry
fixtures hold cleanup to prove Archive's admitted-stop window and Stop's earlier
false idle success; a real gateway fixture rejects an unreadable strand. The
archive fixture does not force commit-before-reply, and the child sender's
port/converter fixture does not exercise TLS membership dialing.

The internal typed result carries these facts into the existing wire error
channels. Validation, ceilings, sequence checks and returned commit rejections
stay conclusive. Missing hubs are classified before send; lost post-send answers
and committed unreadable decisions stay uncertain.

One independent adversarial pass found two further acknowledgement errors and
an inaccurate contract comment. A committed child send could become a refusal
when its optional run metadata was unreadable; it now returns `Admitted`. The
page said a run was stopped when only the asynchronous stop request had been
accepted; it now says `Stop requested.` The refusal documentation now describes
operation-specific uncertainty. The same review's scoped follow-up confirmed
those fixes and a reachable concurrent-send variant: a lost receipt CAS followed
by a failed receipt read must remain uncertain. Its send-specific converter
retains conclusive authority and different-content refusals.

The two child-send regressions drive the actual runtime writer with the memory
backend, not SQLite. They verify one message and receipt before judging replies,
a healthy same-ID resend without duplication, and different-content refusal.
The concurrent fault is armed only by the actual lost receipt CAS. The old
converter and its targeted mutation both fail the intended uncertainty
assertion. With the real helpers and code-mode seed prepared, the complete
agency module passes 211 tests with no skip diagnostics in a primary rerun,
including the six real helper/workflow cases that an earlier unprepared run skipped. These tests do not
establish VM-restart durability. The same reviewer found no material unresolved
defect in the fixes.

The final web state rerun passes 17 tests. Formatting, house lint, documentation,
prelude and generated-client gates exit 0. Lint retains 2,669 warnings and the
documentation gate retains 231 warnings; neither reports an error.

Broad affected checks, hosted CI and applicable Linux signoff remain pending.
No live model call, daemon deployment or issue-level acceptance is implied.

## Exit criterion 2: live drive of sessions.move (2026-11-13)

Criterion 2 of #1137 is "move a laptop session to the box and continue it
there". The code is the checkout step of `sessions.move` (PR #1192,
protocol-change/107 slice 4c), which had run only against in-process fixtures.
This section records the first drive against real daemons. Source baseline:
`024afdadf`. The scripts, logs and daemon homes are under
`/Users/roasbeef/loom-drives/1137-move/2026-11-13/` and are not kept in the
repository.

**Result.** Steps 2 to 5 pass with no manual intervention once the daemons
are started with an explicit `--helper` (finding 3). The failure paths found
two defects that leave a session stuck in `moving` with no operator recovery
(finding 1) and one that delivers discarded edits after a retry (finding 2).
Criterion 2 is therefore met for the clean path and not met for recovery.

### Topology

One Mac, loopback, TLS distribution, three `bin/loomd` processes (built with
`make binaries`, `make server-shipment`, `make codemode-seed`) under separate
`HOME` directories, provisioned with `loom distribution provision plan.toml out
--static` and `loom distribution install out/<node>.loombundle --home <home>`:

| Daemon | Role | Node | Control port | Notes |
|---|---|---|---|---|
| `alpha` | orchestrator, the laptop | `alpha1137@127.0.0.1` | 17451 | `[orchestrators.bravo]` names `checkout_executor = "box"` and `checkout_workspace = "proj"` |
| `bravo` | orchestrator, the box | `bravo1137@127.0.0.1` | 17452 | `[orchestrators.alpha]`, `[executors.box]` |
| `exec` | executor | `exec1137@127.0.0.1` | 17453 | `[workspaces.proj]` with `mode = "worktree"`, root a primary checkout |

The checkout keys belong to the source's row for the destination, as
`docs/configuration.md` says, and not to the receiver. The model was a
deterministic Anthropic-dialect peer on loopback (`fake_provider.py`, which
answers `bash: <command>` with one `bash` tool call), because the repository's
own scripted provider is a test module and cannot be started from a shell. The
daemons were driven through `loom acp` (`acp.py`), `loom sessions move` and
`loom sessions list`. A second pass used the documented Baseten entry
(`docs/examples/loom-baseten.toml`, Kimi K3, credential from
`BASETEN_GLM_5_2`, never printed).

Hygiene: the scripted pass started all three daemons from a shell that had
`BASETEN_GLM_5_2` exported, so each inherited it, the executor included. The
scripted pass never used it, but the criterion "no provider key on the
executor" is not established by that pass. Before the real-model pass the
executor was restarted with the variable unset; `ps -E` showed it absent from
the executor's environment, and the model, asked to run `env | grep -c BASETEN`
in the moved checkout, was told `0`. No GitHub token was present in any daemon
environment or file.

### Steps and observations

1. **Start a session on alpha.** `acp.py new laptop-repo` with two turns. Turn
   one ran `git checkout -b feature/move-drive`, wrote `committed.txt` and
   committed it. Turn two appended to `notes.txt` and wrote `untracked.txt`.
   Session `01a1d475-a431-7a1b-96bd-c90c44f66b09`, branch
   `feature/move-drive`, `HEAD` `cc9c49b`, status ` M notes.txt` and
   `?? untracked.txt`. Pass.
2. **Move.** `loom sessions move 01a1d475-... --to bravo` printed one line,
   `moving 01a1d475-a431-7a1b-96bd-c90c44f66b09 to bravo (operation
   01a1d480-4e37-7eec-a60b-b9617aa6ed70)`, and returned 0. `daemon.move_finished`
   appeared on alpha and `daemon.move_activated` on bravo after 4.1 s (polled
   once a second). Those are the only move lines in either log. The first
   attempt, with the daemons started as the documentation shows, aborted in 5.4
   s (finding 3). Pass after that.
3. **Executor.** The branch `loom/01a1d475-...` in the workspace repository was
   `32ce70d Working snapshot` on top of `cc9c49b add committed.txt`, the
   laptop's `HEAD`, so it descends from it. The snapshot commit held exactly the
   modified `notes.txt` and the new `untracked.txt` (2 files, 2 insertions),
   authored by the source's global Git identity. After the move no tree
   existed, because the scope's clean close removes it. While bravo held the
   session open, `git worktree list` showed
   `<executor state>/worktrees/proj/01a1d475-...` on that branch and no worktree
   after the stop. Hooks, filters, fsmonitor and network: a laptop and an
   executor repository were given executable hooks that fail and touch a marker,
   `core.fsmonitor`, a credential helper, an ssh command and an `origin` URL
   pointing at a listener of this drive. The move finished, the listener saw 0
   connections and no marker appeared. A marker cannot be written inside the
   sandbox, so absence of a marker alone proves little; the stronger evidence is
   that the move finished with failing hooks present on the laptop side, and the
   `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.allow=never`
   arguments of `client/state_apply` and `client/repository_snapshot`. A hook of
   the executor repository did run during the attach (finding 6). Pass, with
   that exception.
4. **Alpha.** The laptop directory's `HEAD`, refs, `git status` and every file
   hash were identical before and after (`snap.sh`, `diff` empty). The session
   file was `01a1d475-....db.moved`. `session/load` on alpha was refused with
   `session <session-id> is owned by orchestrator bravo, which has no address in
   this daemon's configuration` (finding 9). `loom sessions list --all` on alpha
   no longer listed it as a local row, and listed it under bravo as
   `box:proj` (finding 12). Pass.
5. **Continue on bravo.** `acp.py load` on bravo replayed the three earlier
   turns in order, and a new turn ran `pwd` in
   `<executor state>/worktrees/proj/01a1d475-...`, with `git status` clean, `HEAD`
   `32ce70d`, and the committed, modified and untracked content present. Two more
   turns committed `executor.txt` (`b67aaaa`) there; the branch in the
   workspace repository then read `b67aaaa`, `32ce70d`, `cc9c49b`. The real-model
   pass did the same on a second repository: the model read `hello.txt` and the
   README, named the snapshot commit, committed `executor.txt` and the
   executor branch ended at `cad3619`. Pass. One model statement was wrong
   (finding 8).
6. **Failure paths**, each on a fresh session:
   - (a) The row without `checkout_executor`: `loom sessions move` printed
     `loom sessions: not_movable: request refused` and exited 1, with nothing in
     the daemon log. The session opened normally on alpha. Pass for behaviour,
     finding 5 for the words.
   - (b) A `shared` workspace: `moving ...` then `daemon.move_aborted` with the
     executor's words (``the workspace `shared1` has mode = "shared", and a state
     is applied only into a workspace with mode = "worktree"``). The session
     opened on alpha. An unknown name stalled as documented, with the executor's
     words every few seconds. Neither could then be moved to the right workspace
     (finding 1).
   - (c) A 200 MiB repository (200 files of random bytes, 201 MB of `.git`).
     The capture took about 37 s; the executor's `.part` file was 7.1 MB when the
     executor (the PID this drive started) received SIGKILL, and 8.1 MB when
     checked after the kill. After a restart of the executor with no other
     action, alpha's mover finished the move. The stored bundle's SHA-256 equals
     its name, its size is 209,786,883 bytes, the executor branch is
     `Working snapshot` on the laptop's `HEAD`, and the tree entries and blob
     hashes match the laptop's. Whether the send resumed at the executor's offset
     or started again is not observable: no log line says. Pass for outcome.
   - (d) `loom sessions move ID --abandon` on a stalled move printed
     `not_movable: request refused`. A static deployment has no directory, so
     `--abandon` is unavailable, as the help says, and the stalled move cannot be
     ended by the owner. To test the retry rule, the move was instead aborted
     after the landing by making bravo refuse the sender (`bravo` without
     `[orchestrators.alpha]`: `daemon.move_aborted`, "does not list the node").
     The executor held the snapshot. With the laptop's edits discarded (tree
     equal to `HEAD`) and the move asked for again, it finished and the executor
     stayed at the earlier snapshot: its tree still had the discarded `README`
     line and `extra.txt`, which the laptop no longer had. With different
     uncommitted edits instead, the branch moved to the new snapshot and held the
     new content. The known observation is confirmed (finding 2).
7. **Leaks.** `repository-snapshots` was empty on all three daemons and no
   `.part` file remained. Left behind, all by design or by the findings below:
   alpha and the executor each keep every bundle in `states/` (14 bundles, 205 MB,
   including the 200 MiB one); the executor repository keeps one `loom/<id>`
   branch and one `refs/loom/in/<hash8>` ref for every state it ever received,
   including the superseded `990cb1e` (10 refs); the executor ledger holds one
   `open` scope bound to the misspelt workspace `nosuch` and one `closed` scope
   bound to `shared1`. No orphan worktree existed.
8. **Stop.** SIGTERM to the three recorded PIDs and the provider; each daemon
   logged `daemon.stopped`, and no process naming the drive directory remained.
   The operator's `epmd` was untouched.

### Findings

1. **HIGH. A move that failed at the executor leaves a scope bound to the wrong
   workspace, and the documented recovery does not work.** An aborted move to a
   `shared` workspace leaves a closed scope bound to `shared1`; a move to a name
   the executor does not serve leaves an open scope bound to that name. A later
   move with a corrected `checkout_workspace` then stalls for good with
   `the executor's scope for this session is for the workspace shared1` (or
   `nosuch`). `docs/configuration.md` and protocol-change/107 say to fix the file
   and restart the daemon; that was done and the move still stalled.
   `loom executor release` answers `already closed` for the first and `is open`
   for the second, and `--abandon` is refused in a static deployment, so the
   session stays `moving` and cannot be opened on alpha. Recovery that worked:
   none without editing the executor ledger. Evidence: `logs/step6b3.txt`,
   `logs/step6e.txt`, `logs/step6e2.txt`, `logs/step7-leaks.txt`. Responsible:
   `packages/storage/src/storage/exec_ledger.gleam:1904` (`same_workspace`
   binds a scope to the first workspace it names, whether or not that attach
   succeeded) and `packages/client/src/client/move_checkout.gleam:602`
   (`attach_and_apply` leaves the scope it attached when the apply is refused, so
   the "next attach rebinds it" claim holds only for the same workspace).
2. **MEDIUM. A retry after an aborted move can silently deliver discarded
   edits.** Confirmed as the earlier review predicted: after the landing, an
   abort, and the operator discarding the uncommitted work, the retry reports
   `daemon.move_finished` and the executor keeps the old snapshot. The move
   reports nothing about it. Evidence: `logs/step6d-stale.txt`. Responsible:
   `packages/client/src/client/state_apply.gleam:619` and `:784`
   (`holds_tip` treats a descendant of the new tip as applied). A different
   edit is delivered correctly (`logs/step6d-changed.txt`).
3. **MEDIUM. A daemon started from a checkout takes `loom-exec` from `PATH`,
   and the first move failed with an unhelpful message.** `install.helper()` is
   `<erlang root>/bin/loom-exec`, which does not exist for `bin/loomd` from
   `make server-shipment`, so the ladder falls to `PATH`. The drive shell had an
   installed release's `loom-exec` first on `PATH`. Tool calls ran, but the
   capture's Git failed with `sandbox-exec: execvp() of
   '<installed>/bin/loom-exec' failed: Operation not permitted` (seen only after a
   local patch that appended the helper's standard error). With `--helper
   <checkout>/bin/loom-exec` every move worked. The cause of the denial under the
   capture's profile was not determined. The setup document says nothing about
   the helper for a checkout. Responsible:
   `packages/client/src/client/executor_plane.gleam:1630` and
   `packages/client/src/client/serve.gleam:2127` (ladder), and finding 4 for the
   message.
4. **LOW. The refusal text for a degraded sandbox is Linux advice and hides the
   cause.** On macOS the move aborted with "Run this command under the same
   delegated cgroup as the executor daemon (a user service or a systemd scope with
   Delegate=yes)", and the helper's own error was dropped. Responsible:
   `packages/client/src/client/worktree_git.gleam:722` (`failure_words`) and
   `:523` (the result's standard error is not carried).
5. **MEDIUM. The owner cannot learn how a move ended or why it was refused.**
   `loom sessions move` returns after `moving ...`; abort reasons exist only as a
   warning in the daemon log. A destination with no checkout place is refused as
   `not_movable: request refused` with no log line. The `--abandon` refusal has
   the same words. Responsible:
   `packages/client/src/client/daemon/server.gleam:5628` and `:3758` (code
   without a message).
6. **LOW. The executor's `git worktree add` at the attach runs the workspace
   repository's hooks.** A failing `reference-transaction` hook in the executor
   repository made the attach fail and stall the move (it recovered by itself
   when the hook was removed). The apply disables hooks; the attach does not.
   Evidence: `logs/step3-trap6.txt`.
7. **LOW. A repository whose attributes name a filter is refused as "repository
   path has a content transformation"**, naming neither the path nor the
   attribute, and the refusal persisted after the working-tree `.gitattributes`
   and the `filter.*` configuration were removed because `HEAD` still holds the
   file. The documented refusals are a submodule, LFS and a shallow clone.
   Responsible: `packages/client/src/client/repository_snapshot.gleam:1536`.
8. **LOW. The moved session's model is not told.** Its history says branch
   `main` or `feature/move-drive` and an untracked `extra.txt`; on the box the
   branch is `loom/<id>`, the original branch name is gone, and the same edits
   are committed in `Working snapshot`. The real model, asked to commit, said
   `extra.txt` remains untracked, which was false (`logs/real-step5.log`). It had
   named the snapshot commit one turn earlier.
9. **LOW. The refusal on the source has literal placeholders.** `session/load`
   of a moved session on alpha returns `session <session-id> is owned by
   orchestrator bravo ... loom --addr <its control address> --session
   <session-id> --token-file ...`, with no real id.
10. **LOW. Little to read in the logs.** A clean move is one line on each
    orchestrator and two executor lines unrelated to the apply; there is no line
    for capture, send, landing or a resumed send (so 6c cannot be shown to
    resume at an offset), and a stalled move logs a warning every few seconds
    (30 lines in about two and a half minutes).
11. **LOW. The help and message for local sessions are stale.** `loom sessions
    move --help` says it "hands a session on an executor", and `loom sessions
    move ID` with no `--to` prints "Only a session on an executor can move." for
    a local session that can move. Responsible:
    `packages/session_view/src/session_view/move_candidates.gleam:191`.
12. **LOW. The tombstone is not shown as a local row.** The documentation says
    the source lists a moved session as saved; `loom sessions list --all` lists
    it only under the other orchestrator.
13. **LOW. Retention.** The source keeps the 200 MiB bundle after a successful
    move, and the executor repository keeps a `refs/loom/in/<hash8>` ref for every
    state, including a superseded snapshot. The seven-day sweep covers the bundle
    files; nothing prunes the refs.

### Not verified

Two physical machines or a real network (loopback only); a real lid close or
sleep; a directory member deployment (a local session is refused on a member by
design) and so `--abandon` of a local session's move; Linux enforcement (the
Mac's seatbelt was the only jail); a checkout that uses submodules, LFS or a
shallow clone; whether the 6c send resumed at an offset; a hook running on the
executor during the apply, because the sandbox prevents a marker (the evidence
is indirect); the cause of finding 3's `Operation not permitted`; code mode on
the executor in the moved tree; concurrent moves; the web home (no Move for a
local row, as designed).
