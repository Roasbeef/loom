# Next

Read this first for the current work, settled boundaries, and remaining
acceptance. Rewrite it after the next body of work. Detailed measurements and
review findings belong in their own documents.

This edition is checked against main `4d262bd4` and the session-archive branch
on September 14, 2026. Recent merge status was verified against GitHub. The
September 13 project-wide audit was not repeated: its older feature inventory
and performance claims are historical evidence, available with
`git show ebcda151:docs/next.md`, rather than current acceptance claims.

## Where the tree is

| Body of work | Verified state |
|---|---|
| Transcript rendering | #401 and #402 are merged with successful hosted CI. The latter carries etui scroll-region presentation. #408 adds earlier history prefetch and passed hosted CI plus Linux signoff at its final head. |
| Completion handoff | #416 is merged with all hosted CI and exact-head Linux signoff successful. Its terminal retains bounded live fragments until their exact reserved response entry arrives. Protocol 036 records the identity and retirement rules. |
| Terminal input | #413 and etui #2 are merged. Closed input retires both read loops; interactive startup requires terminal input and output before daemon launch. Hosted CI and exact-head Linux signoff passed for #413. |
| Help | #406 and #410 are merged. Help is handled before terminal/daemon startup, including flags following subcommands. |
| Session names | #412 is merged with successful hosted CI. Attachment carries the authorized display name; `/rename` and picker `r` retain session identity and acknowledged names. No final-head Linux signoff was visible in the PR status response used for this audit. |
| Reversible removal | This branch adds archive/restore under protocol 035. The catalogue overlay preserves history and creation metadata; the picker archives ordinarily and reserves permanent deletion for its archive view. Independent review is resolved. Storage passed 104 tests; after integration with #416, 1,802 client and 490 TUI tests passed, along with lint and documentation checks. It is not yet merged. |
| Hook memory retention | #411 is merged with successful hosted CI and Linux signoff. The final three-module patch still lacks a repeated model-backed comparison. |
| Capture lint | #414 is merged with successful hosted CI and Linux signoff at `78406237`. R12 warns on field-only broad record captures; its 85 warnings are a review census, not proof of a leak. |
| Profiling | #409 is merged with hosted CI and Linux signoff at `e14e90e5`. #417 adds persistent daemon profiling configuration and propagation from a profiling client to a newly launched daemon; it remains under validation. |
| Retry and scheduling documentation | #391 is merged and #368 is closed. Open #394 owns the remaining heartbeat documentation. |
| Updating a running daemon | IN PROGRESS in #404, addressing #392. `scripts/install.sh` installs each release into a versioned directory and switches an atomic symlink, so a running daemon, pinned to its physical tree by the launcher's `pwd -P`, is never mutated under. Build identity rides from every launcher through the control-plane `hello` and the private endpoint record ([protocol 037](../protocol-change/037-build-identity.md)); a client reports a client/daemon build mismatch on attach. A daemon drain returns held prompts to their submitters unsent ([protocol 038](../protocol-change/038-held-input-custody-return.md)) and settles an in-flight turn as `Aborted` rather than losing it. The aborted entry still carries the generic `interrupted:` diagnostic; a durable restart reason on the cancel marker awaits its own protocol change. |

### Corrections to the previous edition

The previous edition said #413, #411, #409, #408, and #412 still needed merge
or final validation. They are now merged; their evidence is distinguished
above. It also called #408 a help PR. The help lineage is #406 and #410;
#408 is history prefetch. The renderer description omitted #402. The retry row
called #391 open and assigned heartbeat documentation to closed #368; that
remaining documentation belongs to #394.

The older handoff prescribed a small Escape cancellation repair as though the
current implementation had been rechecked. The earlier relay diagnosis was not revalidated. A new deterministic provider
fixture instead reproduces `[DONE]` parsed from a chunk entering the 100 ms
cancellation grace before owner retirement. Its focused fix is under local
validation on `fix/provider-cancellation`; it retains the same positive monitor
proof and does not change explicit cancellation deadlines.

## What to do next

1. Finish #417 and this archive branch against their final dependency
   set. **Exit:** local gates, independent review findings resolved, hosted CI,
   and Linux signoff at each pushed head before normal merge. Build and verify
   one paired client/server release after those changes land.
2. Inspect remaining memory and cold-start latency. The earlier model-backed
   comparison measured 1,511.755 MiB on its baseline and 695.782 MiB with the
   hook-wrapper fix alone; [the measurement note](design-notes/daemon-memory.md)
   records its composition and limits. A later native inspection found about
   5 GiB physical footprint in an existing daemon, but that daemon has no named
   distribution endpoint. Native sampling cannot attribute Erlang process
   heaps. **Exit:** obtain an authorized process census from the intended
   release and time startup stages before choosing further changes. A source
   merge or newer files on disk does not identify an already running VM's
   loaded modules. Do not restart an active user daemon to obtain the census
   without approval.
3. Finish the parsed-terminal cleanup fix on `fix/provider-cancellation`.
   Its actual OpenAI `[DONE]` regression reproduces the 100 ms conversion of a
   completed answer to unconfirmed cancellation. **Exit:** owning package
   gates, independent review, hosted CI, and Linux signoff on the final head.
   A timeout must not become proof of cleanup.
4. Preserve the outstanding auth boundary for jailed CLI tools. Litbucket's
   macOS credential store uses Keychain, which is not made available merely
   because its GitHub login completed in a jail. The existing host secret
   resolver can supply `LITBUCKET_TOKEN` to a new session; configuring that
   credential remains subject to the owner's approval. **Exit:** a scoped
   resolver and verified authentication without exposing tokens in logs or
   granting the jail general Keychain access.
5. Keep longer-term work tied to its own acceptance. The issue-state audit
   found #369 (imported hooks), #392 (update path), #394 (heartbeat docs),
   release issues #247/#241/#246/#244/#245, and maintenance issues
   #248/#296/#286/#283/#345 open. Their implementation state was not re-audited.
   **Exit:** check the owning issue and reproduce its symptom before changing
   code. Advisor deferrals and Herdr-side work likewise need a fresh targeted
   audit; this edition makes no completion claim for them.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Archive is visibility, not initialization or revocation.**
[Protocol 035](../protocol-change/035-session-archive.md) keeps `Reserved` and
`Saved` unchanged. Archive and restore are owner mutations serialized with
runtime admission and require no live slot. Restore neither opens a runtime
nor restores a workspace default. Memberships, domains, and conversation files
remain; ordinary owner/member pages exclude archived rows before pagination.

**Activation is explicit and uncertain mutations are not retried.**
[The daemon ruling](design-notes/single-daemon.md#execution-ruling),
[ADR-009](adr/009-record-terminal-attempt-custody.md), and
[ADR-010](adr/010-retain-one-unsent-terminal-command.md) own these boundaries.
Listing and preview do not start saved sessions.

**Cleanup requires the original owner's evidence.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains native
custody until observed exit. [Protocol 028](../protocol-change/028-provider-failure-context.md)
preserves diagnostics without weakening that proof. Timeouts and late `noproc`
are not retirement witnesses.

**Presentation does not own durable truth.**
[Protocol 030](../protocol-change/030-context-observation.md) reads captured
state; [protocol 031](../protocol-change/031-tool-output-stream.md) bounds live
tool output; [protocol 033](../protocol-change/033-abort-halts-held-input.md)
defines the held-input halt. Exact entry identity, rather than equal text or
capture timing, determines the streamed response handoff in #416.

**Authority and process boundaries remain explicit.**
[Protocols 015](../protocol-change/015-daemon-control-and-session-attachments.md)
and [020](../protocol-change/020-minimal-jail-root.md) define server-owned
activation and jail policy. Portable packages stay free of I/O and externals;
process ownership follows [the Weft mapping](weft.md). Use the design/spec and
owning architecture documents for the older subsystem rulings.

## Deliberately open

None of these is unfinished work somebody forgot.

- The 5 GiB daemon observation has no Erlang process attribution. The merged
  closure repairs and R12 census do not establish its current root cause.
- The final memory comparison and startup stage timings remain unmeasured.
- #243 remains the approval-policy question and #85 remains optional microVM
  work, according to the issue-state check.
- The older search prompt/trace questions, advisor deferrals, and Escape's
  interaction with non-client starters remain unverified against this baseline.
  Consult their owning documents before treating them as current defects.

## How to verify

```sh
make check
make doc-check
make codemode-seed
make release-smoke
bash scripts/test.sh storage --match catalogue_test
bash scripts/test.sh client --match daemon_manager_test
bash scripts/test.sh client --match daemon_server_test
bash scripts/test.sh tui --match session_delete_test
```

**Capture the gate's own exit status.** A successful log reader proves nothing
about the command that wrote the log. **Use one build/gate at a time per
checkout.** Enforced code-mode worktrees belong outside `/tmp`, which the Linux
jail replaces with scratch.

Use normal dirty-scheduler capacity for SQLite tests. Restricting both dirty
scheduler classes to one produced a history-reader timeout that passed unchanged
with `ERL_FLAGS='+S 4:4'`. A Hex retry wrapper is appropriate only for dependency
fetch failures, not test failures. Keep modules using VM-global capability
fixtures in `scripts/serial-tests`; otherwise parallel EUnit can exchange their
fake replies.

Only `scripts/signoff.sh` posts Linux signoff for a pushed head. Ordinary local
package gates do not establish Linux enforcement or shipment acceptance. See
[execution](execution.md) for the rest of the operational rules.
