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
