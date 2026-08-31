# Next

**Read this first.** It is the handoff between sessions: where the tree
actually is, what to do next, and the decisions already taken so you do not
re-litigate them.

Keep it current. When you finish a body of work, rewrite this file — it is
worth more than any status comment.

---

## Provider stream ownership (#131)

PR #133 (`provider/cancellable-streams`) is rebased on `main` at `9849b3f`.
It implements #131 across the provider, runtime, and client wrapper boundaries.
A `StreamHandle` carries an idempotent cancellation capability and an optional
owner pid; when present, normal owner exit acknowledges that every asynchronous
descendant has stopped. That pid is a deliberately boring custodian rather
than a worker that can crash while retaining live children. A custodian
publishes first, adopts each worker and child owner synchronously, and only
then permits work to begin. Cancellation closures run on disposable helpers,
so a faulty closure cannot take the public drain witness with it.

The operational invariant is stronger than late-result suppression: once a
strand effect no longer owns a provider request, its runtime worker, client
relay and observer, fallback guard and pump, native HTTP owner, and dedicated
request handler must all drain before replacement work begins. Runtime
timeout, explicit abort, driver restart, worker crash, wrapper death, and
direct consumer death now propagate along that chain. A bounded grace decides
whether the public terminal is confirmed or `CancellationUnconfirmed`; it does
not authorize killing the drain witness. `DrainProofLost` separately records
an abnormal transitive owner exit; none of these terminal results can advance a
fallback or retry. Critical callers install a `DrainWitness` before begin, so
they retain the original exit reason rather than observing a late `noproc`.
The frozen contract change and race table are in
`protocol-change/010-provider-stream-cancellation.md`.

The only provider-specific Erlang remains the existing `provider_ffi` shim.
Gleam cannot selectively receive raw `{http, ...}` tuples, and OTP exposes
`httpc` cancellation as an asynchronous cast rather than a socket-drain
acknowledgement. Three small externals prepare, begin, and cancel one native
owner. The typed transport returns `PreparedRequest(running, begin)`, so its
raw owner is publishable before `begin` can touch the network. That owner
disables redirects and automatic retries that could migrate the
handler behind a stable request id. The manager publishes the request's exact
handler PID in its protected table before successful admission returns; a
request-local unlimited handler allowance also prevents this dedicated request
from entering the manager's queue. The response callback pauses inside the
handler until the owner acknowledges that its exact monitor is installed, so a
fast terminal cannot delete that row first. The normal capture path remains one
O(1) lookup. Any miss enters a deadline-bounded scan which asks `httpc_handler`
processes for their current request. A busy handler, no match, or an unfamiliar
private layout keeps recovery inconclusive and the owner alive rather than
authorizing drain; expiry destroys the witness abnormally. Provider ownership
above that raw mailbox, fallback, deadlines, and terminal arbitration remain
typed Gleam.

The runtime closes both ends of its former publication gap. Production exposes
a `PreparedProviderSurface`; each layer returns a parked `PreparedStream`,
publishes its custodian to the parent owner, and only then grants the begin
permit. Route resolution, secret lookup, transport startup, and socket work all
remain behind that permit. Immediate `ProviderSurface` values remain for
in-memory fakes which own no external work; they may still use a self-reaping
in-memory owner to model cancellation. Reaper generations live
in a drain ledger before the restartable name registry, so a replacement waits
for the ledger's original monitors to acknowledge every older generation.
`api.close` captures and monitors the live ledger
before terminating the root, then releases the lease only for its clean
normal/OTP-shutdown exit. A missing or killed ledger fails closed and leaves
the lease to its TTL. Tests pin cancellation
before begin, startup death, wrapper and gateway worker crashes,
handler-delayed socket closure, manager replacement, redirect cancellation,
fast terminal capture, timeout drain, restart ordering, and close/reopen
exclusion. Shared fixture transports also monitor their preparing process until
begin transfers custody; failure inside `prepare_streaming` therefore retires
the parked owner instead of leaving it unpublished.

The first cold review and exact-head CI rejected `fd0c9e3`. CI seed 33 proved
that even a 500 ms wall-clock retry budget could expire while a rest-for-one
tree was still rebuilding. Intervention admission now retries while the root
supervisor remains alive; a dead root, rather than scheduler timing, is the
failure boundary. Review also found that a handler-supervisor restart can
orphan a live `httpc_handler`, that handler discovery itself introduced
latency and orphan risks, and that abnormal reaper or transitive-owner exits
must not count as drain. The corrective pass made exact table capture the normal
path and distinguishes leaf completion from transitive proof. A second review
found the fast-terminal deletion race, late monitors in the gateway and
distiller, and the fixture publication gap; the current callback handshake and
retained typed witnesses close those paths. The final adversarial pass found
two more timing assumptions: each late post-cancel delta renewed a relative
grace timeout, and a replacement installed a fresh monitor after the drain
ledger returned predecessor PIDs. Cancellation now schedules one deadline per
layer, while the ledger retains each claim until its original monitors prove
that exact predecessor snapshot drained. Deterministic delta-flood and
ledger-barrier tests pin both failures. The replacement initializes before that
potentially long barrier, while its reaper claims the ledger directly. A
private PID-bound subject returns the claim and every other incarnation-local
callback, so the actor can retain an abort request without admitting recovery
work and a predecessor cannot settle replayed work through the replacement's
stable name. A negative control restores the old stable-name retry route and
makes the regression admit a second provider attempt. The same pass found that
a gateway guard stopped consuming attempt registrations after cancellation
expired; it now rejects late prepared attempts until the pump exits, preserving
both transitive ownership publication and bounded drain.

Issue #141 is folded into this branch by explicit operator direction. Every
package now requires Gleam 1.18, the supported runtime floor is OTP 29, and PR
and nightly CI pin the exact local pair Gleam 1.18.1 plus OTP 29.0.5 (ERTS
17.0.5). OTP-only compatibility branches and old-style Erlang catches are gone.
The Linux gate builds and smokes both release profiles so its retained log can
replace the distribution guide's old OTP 28 measurements with observed OTP 29
values.

The completed focused gates are green: provider 149, runtime 90, client 576,
and conformance 68. `make check` exits zero, `make e2e-codemode` passes 210
tests, and the OTP 29 release and both distribution profiles pass their
no-host-Erlang smoke with the bundled SQLite NIF. The first 200-seed soak
exposed two one-second ownership-handshake timeouts: under scheduler pressure a
live reaper could answer late and make a provider effect disappear without a
terminal. Those handshakes now wait for either their typed acknowledgement or
the reaper's monitored death, and the complete 200-seed rerun passes.

Three independent cold reviews approved the simplified implementation head
without a P0, P1, or P2 finding. That final simplification removed native
accounting which could not truthfully bound `httpc` before delivery and removed
fragment-local redaction which could not protect secrets split across streamed
deltas. Issue #147 owns a transport boundary that can bound non-success bodies
before buffering, and issue #148 owns stateful cross-fragment response
redaction. Neither limitation weakens #131's cancellation and drain ownership
contract; keeping them separate avoids claiming security properties the
current transport does not provide.

The final 2,000-seed Nightly found seed 584 before merge. A fault-free script
put an abort and a steer at the same logical trigger; because abort is an
asynchronous cast, Linux closed the run before the synchronous admission while
macOS admitted the steer first. The simulation now preserves queue-admission
order and sends same-moment aborts after those admissions, giving its comparison
oracle one baseline without changing the runtime's abort race. Seed 584 is a
pinned corpus test.

## Platform-strict enforcement is the production default

PR #134 merged WP-H phase 2 at `5289c4e`. The helper now translates
`SandboxPolicyV1` into a generated,
deny-default Seatbelt profile: host-visible reads, parameterized writable
roots, final protected-path carveouts, private scratch, local capability
sockets, and no internet access unless the policy grants `NetworkFull`. The
broker selects the Darwin enforcement matrix from the helper's hello frame,
and the macOS CI lane runs the live self-test, jailed end-to-end, and code-mode
end-to-end rather than accepting the former platform skip.

The boundary is deliberately narrower than Linux's. Darwin's finite
`RLIMIT_AS` is attempted but rejected by current kernels; `RLIMIT_NPROC`
counts the whole login account and is not installed without a concurrency
reserve above the existing process count. The sample still races unrelated
same-user forks. A process-group plus birth-qualified process-table tracker
reaps descendants it observes after `setsid`, but no PID namespace, subreaper,
or stable process handle closes the rapid-reparenting and PID-reuse races.
Output drainage is bounded if a missed descendant retains a pipe. Every
execution reports those exact gaps, and `FullEnforcement` refuses them. ADR-006
is the ruling; do not
turn the passing observed-escape probe into a claim of kernel lifecycle
containment.

That truthful report exposed the next product bug: the production default also
selected `FullEnforcement`, so every ordinary Darwin `code_mode` call failed
before compilation. `PlatformEnforcement` is now the production default. Linux
remains fully strict. Darwin requires Seatbelt, all enforceable rlimits, and an
explicit applied-or-skipped report for every layer, but may admit only
ADR-006's three named gaps. `--full-enforcement` keeps the stronger
cross-platform contract and `--best-effort` remains the broad development
override.

The focused broker, prompt, and client gates are green. `make check` also
passes with its own exit status, including the 208-test real code-mode suite
under `PlatformEnforcement`, and `make doc-check` reports zero errors. A second
agent rebased the native eTUI onto `4f5e012`, started a fresh server with no
enforcement override, and asked K3 to run a minimal `code_mode` program. The
durable result completed with `platform strict live`; both the build and node
reported Seatbelt filesystem and network confinement, CPU and file-size
rlimits, and only ADR-006's three skipped layers. The remaining exit criterion
was an adversarial review of the exact change.

That review is complete. It found one behavioral defect before the PR: prompt
bytes were pinned without the enforcement demand that made their sandbox claim
true, so a resumed session could keep stronger words while booting under a
weaker demand. `prompt/system` now stores `{text, enforcement}` atomically. A
same-demand boot reuses the bytes; a changed demand or a legacy string pin
renders and pins once; a malformed harness-owned record refuses the boot. The
review also found three stale descriptions of the production default and
corrected them. The full `make check` gate passes at the reviewed head after a
transient Hex fetch failure on the first attempt, and `make doc-check` reports
zero errors.

## Code-mode vetting admits current Gleam syntax

Issue #89's parser split is repaired by raising codemode's Glance floor from
1.0 to 6.1. The vetter now accepts the labelled-argument shorthand used by
Loom's own house style, together with the other compiler-valid constructs the
issue identified. The corpus pins calls, patterns, `assert`,
`let assert ... as`, `echo`, and string-prefix alias patterns, while a live
client fixture sends shorthand through vetting and the hermetic compiler. The
obsolete repair note has been removed so a parse failure no longer teaches a
restriction that does not exist.

---

## Active evaluation: issue #114

Branch `client/etui-tui` carries an opt-in pure-Gleam client in
`packages/tui_gleam`; PR #136 is on `main`, but it does not replace the shipped
Go client. The client works in a real Herdr
PTY, attaches to the real gateway, opens searchable model and agent overlays,
and renders assistant CommonMark through Mork into etui spans. Typing `/` now
opens a prefix-filtered command palette. `/agents` has a real selection cursor;
Up and Down move it and Enter opens the selected strand's transcript. `/notes`
keeps the server-injected note digest out of operator speech while retaining an
explicit inspection surface. Strand switches request that strand's effective
configuration before replacing the model label, and long agent lists keep the
selected row inside the inspector viewport.

The transcript distinguishes tool calls, results, and failures. Bash calls show
their command, `apply_patch` calls render a bounded unified diff, and structured
`code_mode` programs use fenced Gleam rather than escaped JSON. Long prompts
wrap into a one-to-four-row editor without changing submitted bytes. Page Up,
Page Down, and the mouse wheel share one clamped tail-relative viewport. The
footer reports the server's complete usage ledger: input, output, cache
read/write tokens, and accumulated cost. Active work uses an animated title
marker rather than relying on the word `thinking` alone.

The historical render cache is now per record. Stable entries keep their
already-wrapped Mork rows; only the live stream buffer is rewrapped for a new
fragment. Background-strand deltas no longer invalidate the visible transcript,
streams accumulate fragments without repeatedly copying their prefix, and
records are stored newest-first. This closes the history-sized work that was
visible during streaming. Upstream etui PR
[#8](https://github.com/lupodevelop/etui/pull/8) adds the same-Buffer diff
short circuit and state-dependent poll timeout requested in issues #6 and #7.
The Loom adoption returns the exact cached Buffer term for an unchanged frame,
polls at 40 ms for 320 ms after activity, and then backs off to 400 ms. A
matched 120x60 idle sample moved from 5.1-5.4% of one core to below `top`'s
0.1% display precision; CPU-time growth implies roughly 0.07%, so treat the
result as a directional greater-than-50x idle reduction rather than a general
throughput claim. Until upstream merges the PR, the package is temporarily
pinned to the exact commit on the contributor fork.

The footer follows the compact project/status layout used by modern coding
clients. It discovers the surrounding repository once at startup, showing its
abbreviated path and branch beside the selected model. At narrower widths it
reserves a second row for the complete usage ledger and agent status. If those
sections collide, agent status moves to a third row so etui cannot truncate the
usage tail first. Repository marker and HEAD reads validate and consume one
descriptor, accept only regular files up to 4 KiB, and bound displayed refs.
Expanded tool output also strips complete ANSI CSI and OSC sequences before
rendering. Malformed sequences stay visibly inert instead of consuming the
ordinary transcript text after them.

Websocket startup now runs in a monitored, unlinked helper with a five-second
deadline. A dependency initialiser panic or silent dial becomes a client error
instead of killing or hanging the terminal; success restores the socket actor's
link to the caller. The focused package gate passes with 47 tests. Its expected
panic regression prints an Erlang crash report while proving that the parent
survives. The measured compatibility cost remains: etui needs Gleam 1.16+, and
Mork's Erlang path needs OTP 28+, above Loom's advertised OTP 27 floor. The
package therefore remains outside the root package and release lists.

A fresh default-policy session completed the combined eTUI-to-code-mode path on
Darwin. Both the hermetic build and satellite reported enforced Seatbelt
filesystem and network confinement plus CPU and file-size limits, with exactly
ADR-006's three named gaps. Do not replace this proof with `--best-effort`; the
supported Darwin contract is `PlatformEnforcement`.

Image drop is deliberately not smuggled through the text-only command.
`protocol-change/010-prompt-content-blocks.md` is accepted and adds the
version-skew-safe `prompt_content` command carrying the existing total
`UserBlock` codec. The gateway preserves block order and admits exactly one
durable user message; malformed, empty, or unknown content refuses the whole
command. The eTUI recognizes one regular PNG, JPEG, GIF, or WebP from terminal
paste, bounds the read at 20 MiB, keeps local paths off the wire, and leaves
live-strand steering text-only. Package tests cover the classifier, bounded
reader, ordered wire frame, total decoder, and durable admission. A real
terminal drag event remains outside the automated harness, so do not mistake
the protocol and transition coverage for terminal-emulator proof.

Escape still exposes a server-side cancellation boundary beyond this client
wave. Admission can now send an abort during the prompt-to-live transition, but
the provider relay, pump, and HTTP transport are not linked to the waiter that
the runtime kills. Late deltas also lack operation identity at the TUI boundary.
Treat "the request stopped billing and cannot contaminate its successor" as
unproved until that runtime lifecycle is repaired and tested.

Before adoption, implement protocol-change/007 approval with exact action and
grant echo, then sparse-sequence reconnect/catch-up behavior. After those gates
pass, decide the toolchain floor and release replacement explicitly; do not
silently add this package to `PACKAGES` or replace `bin/loom-tui` before that
decision.

---

## State, as of `main` at the end of phase 3

Everything below is on `main` unless it says otherwise.

**#106 — MCP through code mode — is done and on `main`** (merged at
`0f4dfac`'s lineage): generated per-server capability modules, wired end
to end, proved against a real server process, documented in
`docs/architecture/mcp.md`, closed on the issue with the rulings. Its
follow-ups are filed: #108 (HTTP+OAuth), #109 (the server-jail decision,
undesigned), #110 (wild-server e2e), #111 (elicitation), #112
(listChanged), and #107 (async code mode, with the state-machine
argument and Claude Code's replay-continuation prior art on the issue).

**#15 — one canonical id per session — is done and on `main`**
(`protocol-change/008`): a UUIDv7 in the reserved `session/id` fact cell,
minted at first open under a CAS, adopted verbatim on a lost race,
projected into the SQLite catalog as repairable convenience (the
lease-free `sqlite.identity(path:)` read exists for cross-session
tooling), carried through fork parentage — a fork into an
already-identified destination now refuses — and scoping `events/search`
through an opaque `SessionKey`. One residual, tracked on the issue: the
generated `events/sql` module is hand-mirrored (no `sqlite3` in the
build container); a statement-for-statement pin bounds the drift and
`make gen-sql` on an equipped host restores byte-identity.

**#14 — model routing — is done and on `main`** under the rulings
recorded on the issue and `protocol-change/009`: on-route dispatches walk
the role's chain inside one attempt with the turn's thinking overlaid on
every walked target; off-route strands and deferred polls stay
`ForResolved`; children seed from the `Subagent` route; model facts and
admission follow the identity per query, read from the step's own
snapshot (the closing review's one behavioral catch — a mid-wait
`set_config` no longer makes admission describe a model the attempt
never reaches). The M5 429-storm conformance row is real. **#19 ruled
itself out of the release by its own text** — re-checked, dispositioned,
no work.

**#16 + #105 + #91 item 1 — the harness-side capability bridge — is
done and on `main`.** All eight workspace capabilities route:
`fs.read`, `fs.list`, `fs.write`, `fs.edit`, `kv.get`/`set`/`delete`
and `report.emit`, as `satellite.ServedHere` through
`codemode/workspace` — a seam record of injected closures wrapped in
front of the MCP arm and `satellite.default_router`, zero broker
changes, no `CallSpec` anywhere on the path. The closures are built
from `tools/fs`'s own boundaries: reads through `resolve_real` +
`read_text_file`, writes through `resolve_writable` — `resolve_real`
plus the protected-path refusal #105 added to the shared write path, so
the model's own `fs_write` gained it in the same commit and a satellite
write to `.git/hooks/post-checkout` is refused in band (proved through
a real jailed program, with the mutation run leaving the hook on disk
when the policy entry is removed). `kv.*` is `client/scratch`,
ephemeral and bounded three ways; `report.emit` is `codemode/artifact`,
one closure on **both** seams (#91 item 1) with a 1 MiB per-emit bound
and a 64-admission ceiling, content-addressed into the session's one
blob store — which the base policy now protects from jailed
pre-planting.

**The `fs.edit` ruling is made and implemented** (recorded in
`codemode/workspace`'s module doc): honest whole-file find/replace —
each `find` exactly once (zero → `StaleContent`, which now means "the
file no longer contains your text"; several → refused ambiguous), in
order, all-or-nothing, read-apply-write inside one served call. The
harness editor's anchor discipline was **not** synthesised on the
program's behalf; `cap/fs.Replacement`'s doc stopped lying. Real pins
remain open as a later layer.

The branch went through a full adversarial-review cycle (review →
verified fixes → re-verify by the same reviewer). Its findings are
worth knowing: a relative `protected` entry used to fail open on the
harness path (now refused in band *and* at boot via
`serve.base_policy_fault`); the component-prefix predicate existed as
three copies (now one public `policy.covers`); blobs are now
established by atomic rename, never direct write. `make check` passes
end to end at the head.

`main` holds phases 1 and 2 plus #106, the bridge, #15, #14, #27
(triggered rules; dead-strand follow-up is #113), #28 (memory M1;
accepted gaps are spec-gaps items 6–9 in its section) and #29 (memory
M2 — the memory session, `client/distill`, the protected sidecar
digest, the `remember` door; erasure cascade filed as #115, the
recorded limits in spec-gaps' M2 section). **Phase 3 is complete.**
Every `phase:3` release-blocker landed through the same loop — a
measured census, rulings posted to the issue, an implementation
worker, and a closing adversarial review with per-finding
re-verification — and #19 dispositioned itself out by its own text.
The debt wave that follows it is **built and in review as four PRs**,
not yet merged: **#125** (events test hygiene, closing #119),
**#126** (dead-strand rule holds, closing #113), **#128** (#91's four
remaining defects), and **#130** (the erasure cascade, closing #115).
**Merge #125 first, then the other three in any order.** Only #125 is
genuinely ordered: the events flake it fixes went deterministic and
runs before every other package, so until it lands `make check` cannot
reach `client` at all. The remaining three share no source file — their
only common surface is `packages/client/CLAUDE.md` and its mirror,
which they append to in separate regions. Measured rather than assumed:
all four merge clean in sequence, and the combined four-branch tree
passes the full gate and `doc-check`. If a tiebreak is wanted, take
#128 first of the three — it is the widest (four packages plus the
regenerated prelude), so it lands while the others are still cheap to
rebase.

---

## Start here: after phase 3

The debt wave is done and awaiting merge (the four PRs above). What it
turned up on the way is worth reading before the next one, because most
of it is about the gates rather than the code: **#129** — `check.sh`'s
`tee /dev/stderr` truncates a redirected gate log mid-run, so the log
half of `execution.md` §4's discipline is silently destroyed while the
exit code stays honest (the pipe route, `2>&1 | tee log` reading
`PIPESTATUS[0]`, is immune, and is what an agent should reach for here);
**#127** — a third load-sensitive test, after #119's and storage's, each
occurrence costing an agent a control run to exonerate its own diff;
and the review-driven follow-ups **#122**, **#123** and **#124**.

Then **phase 4, the promotion ladder** (#30–#33,
#100), which #16 gated and which is now unblocked; **phase 5** (#25
LSP, #26 DAP) starts from the supervised stdio substrate the MCP
client already is. **#107** (async code mode) sits outside the ladder
with its design dossier on the issue, awaiting prioritization.

### The MCP increment, in detail

**#106 — MCP through code mode: the first increment is done.**
`docs/architecture/mcp.md` is the living account; the rulings and their
reasons are on the issue. The shape: generated per-server capability
modules (`import cap/mcp/github`), never registered harness tools and
never a generic dispatcher; `[mcp.<name>]` in `loom.toml`, file only;
`packages/mcp` holds the protocol codecs, the stdio client actor, the
façade generator and the value interchange; `client/mcp` starts one
client per configured server at boot, widens the workspace seam's
allowlist/description/generated-table/router as one field, and answers
`mcp.<server>` as `ServedHere`; `codemode.execute` narrows the generated
table to the vetted program's own imports before the builder vendors
them into the prelude — fifty configured servers cost an unimporting
program nothing. A checked-in `escript` fixture proves it against a real
server process over a real pipe, wire names byte-identical end to end,
including the `isError` leg and OS-pid teardown. The hostile-`tools/list`
corpus is **built, not owed**: mangling digests on any change and a
collision refuses the server; description text is stripped of every
control/direction codepoint and a `glexer`-shaped `@` backstop asserts
the cage held; schema reading is three-tier and total with nothing
silently dropped; tool count, surface bytes, listing pages, result size
and result depth are all capped with worded refusals.

Still open on #106, deliberately: the **jail decision** for MCP server
processes — `mcp/transport.PortTransport` spawns unjailed and the seam
is where jailing would attach; this is undesigned, not merely unbuilt —
an e2e against a third-party server from the wild, and the deliberate
v1 cuts with their reversal triggers (HTTP transport, OAuth,
elicitation, `listChanged`, restart supervision; see the architecture
doc). **#107** (filed this increment) is the async-code-mode question —
kept-alive satellite versus continuation handles versus a
replay-with-memoized-effects shape; its comments carry the
state-machine-expansion argument and the prior art.

The finding carried into phase 5 held: the MCP stdio client **is** the
supervised long-lived stdio substrate #25 needs, and it now exists
(`mcp/client` + `mcp/transport`), so phase 5 starts from something
rather than nothing.

**Phase 5** is the language-service tier: **#25** (`lsp_*` over a sandboxed
per-project client) and **#26** (`dap_*` over the same port seam). Both need
a long-lived stateful stdio peer that phase 3 deliberately does not build.

Phase 4 is the promotion ladder (#30–#33, #100) and is built directly on the
router being real, which is why #16 gates it.

---

## Reading the issue tracker

Every open issue carries exactly one `phase:` label. **`phase:debt` is the
largest bucket and that is correct** — it means found work with no phase
gate, picked up in a debt wave between phases, and most of this tracker is
review-wave findings rather than planned milestone work. Do not read a
thin `phase:3` as a light phase; read it as an honest one.

*(Housekeeping: `phase:debt` was created implicitly by first use, so it has
GitHub's default grey and no description. Someone with web access should set
them.)*

### The dependency edges that matter

- **#99 is the root of the phase-1 subtree.** A check that has never
  completed cannot be made required (#1), and CI is the only environment
  likely to have a Landlock-capable kernel (#62).
- **#16's thirteen names are not equally blocked.** `#105` blocks only the
  `fs.write`/`fs.edit` arms; `#25` blocks the four `lsp.*` names; the egress
  proxy blocks `net.request`. **Nine of the thirteen are unblocked today.**
- **#16 blocks #30**, and therefore the whole phase-4 ladder — a skill that
  can only call `proc.run` is not a capability. This is the phase-3 → phase-4
  seam.
- **#30 → #31 → #32 → #33** in order, and #32 does not close until #33 does.
  **#100's classification work belongs before or during #32**, not after: it
  exists to shape the hook vocabulary while #32 is designing it.
- **#80 blocks #81** — the full-argument pager must render through #80's
  sanitiser, or a 40 KB model-controlled blob pages straight into a terminal.
- **#73's rule-A fix gates #74's census** — the fixes are independent, the
  measurement is not.
- **#89 no longer blocks #30**: L1 can re-vet stored source containing current
  Gleam syntax without rejecting the repository's own labelled-argument
  shorthand.

Decide-together pairs: **#77 + #82** (same single-latched door, spend site
and raise site). **#66 + #79** (bounding retries trades capability for
security with nowhere for capability to go until the session-widening valve
exists). #58's terminal-counter race was separate from #69's intervention
waiter. The CI repair branch now fences terminal accounting and gives
intervention payloads a correlated durable identity; retain that distinction
when closing the two filings after the branch's soak gate is green.

### Known-stale filings — re-scope before picking up

- **#42's scope shrank** when #35 landed; it may now be a few log calls
  rather than an events-plane addition.
- **#91 item 1 overlaps #16**: both cover `report.emit` being unrouted, on
  the orchestration and workspace seams. Service both seams in one change or
  each issue half-fixes it.
- **#73's baseline numbers are already moving.** Re-measure; do not trust
  the header.
- **#98 is a research record whose question is settled**, carried forward
  into #100. It will sit in the phase-4 bucket looking like a task.

**A general warning, learned twice this week.** An issue's own severity note
can be stale in either direction. #68 was filed as "benign today, fix it when
#65 lands"; #65 landed, and a plausible reading said #68 had therefore become
live and urgent. The code said otherwise — it had been fixed inside #65 and
never closed, with a test named for it. **Read the code before acting on a
filing's self-assessment, including when the filing sounds alarming.**

## Standing decisions — do not re-litigate

- **The ledger keys on `{op_id, step_id}`; paths key on
  `{op_id, step_id, source_index}`.** The pair is the *batch* identity the
  broker pools on; the triple is the *execution* identity. `source_index` is
  deliberately absent from `ExecIdentity`, whose exports feed ledger keys —
  adding it would mint one ledger per `code_mode` call and read the pooled cap
  as a per-call cap by another door. ADR-005's addendum has the argument.
- **The abort-epoch table is measured, not pruned.** Pruning is unsafe in both
  directions and the dangerous one is silent. See #104.
- **A host missing a code-mode prerequisite registers no `code_mode` tool at
  all**, deliberately: a tool definition is a byte prefix of the provider's
  cached region, paid on every request of every strand for the session's life.
  The *reason* it is missing is what got better, not the mechanism.
- **Code mode ships in the main release artifact**, with `DIST_CODEMODE=0` as
  the opt-out. See `docs/distribution.md` and #102.
- **MCP is code-mode only** (#106): generated per-server modules, never a
  generic `cap/tools.invoke` dispatcher. A generic dispatcher does not
  falsify the vetting theorem — it collapses its discriminating power, since
  the bound becomes "the whole registry, for every program", leaving one
  layer where code mode was built to have two. The bound is per *server*, not
  per tool, and that is deliberate: a human trusts a server. The
  once-unanswered question — `tools/list` is attacker-controlled JSON
  compiled into allowlisted source — is now answered structurally in
  `mcp/codegen`: server text reaches a module only as sanitized comments
  and escaped literals, names mangle with a digest and collide into
  refusal, and a backstop scan proves per module that the cage held.
  `docs/architecture/mcp.md` carries the whole argument.
- **R3 and R8 will never gate.** Both over-report by construction; they are
  censuses, and measuring rather than refusing is the point.

---

## Known-open, deliberately

- **CI has never completed a run** (#99) — all jobs die in under four seconds.
  This is owner-action; local `make check` is the real gate today.
- **`make lint` reports ~322 warnings at 0 errors.** That is the designed
  state. R5's promotion is five one-line fixes away (#73 names the files);
  the growth over the old ~306 is the mcp work's R3 census entries, the
  same `_ ->`-over-`JsonValue` shape `client/protocol` carries.
- **Jail and sandbox tests degrade in this container** — no cgroup v2, no
  Landlock. `make selftest` says what the host actually enforces. Failures
  there are environmental until run on a real host; #62 is that nobody has
  ever run Landlock.

---

## How to work here

Read `docs/execution.md` before dispatching sub-agents. It carries the wave
pattern, the briefing checklist, the verification standard, and the hazards
that have already cost time — including the two that will catch you first: a
verification worktree under `/tmp` breaks code mode, and `make check > log;
echo $?` reports the exit code of `tail`, not of `make`.

Three skills now live in `.claude/skills/` and earned their keep on the
#106 work: `/advisor` (a read-only design consult before code), `/advisor-review`
(the closing gate — one independent top-tier pass over a pinned diff:
invariants, simplification, live variants of the shapes just fixed; verify
every finding yourself, fix, then re-verify through the *same* reviewer),
and `/technical-writing` (read all six references before writing prose).
The two review cycles on this branch each returned real findings — a
quadratic over attacker-controlled schema input, an invisible-character
gap, servers spawned that nothing could reach — that same-author review
had read past. Treat the closing review as part of finishing, not polish.
