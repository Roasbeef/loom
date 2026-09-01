# Four decisions

Verdicts on the four open decisions in `docs/issue-plan.md` (D1–D4), argued
from the tree as built at `c747fb5` (2026-08-25). Every load-bearing claim
below was checked against the code, and where the brief or the plan said
something the tree does not, the correction is stated where it matters and
collected again at the end. Two of the four decisions turn out to be
differently shaped than their option lists: D1 is two questions wearing one
label, and D3 is a bug plus a decision. The verdicts, one line each:

- **D1** — raise on every policy refusal, deduplicated, and keep the
  in-band error; but the release-blocking work is not the raiser, it is
  the spend path, which is severed in production below the point this
  decision was framed at.
- **D2** — promote to error with three amendments: check only backticked
  citations, exempt `docs/review/**`, fix the two real drifts. The plan's
  "backlog of about four" is two real fixes and three checker false
  positives.
- **D3** — fix the silent-acceptance bug at the strict tier regardless of
  the rest (release scope), then take option (b), delegation as
  configuration — which also converts the CI known-gap into a required
  probe. Reject (c).
- **D4** — split: WP-J 16 yes, as WP-N's first commit (with its invariant
  restated); WP-J 15 yes, into WP-N and out of release issue #4, because
  it is D1's unresolved spend mechanism wearing a code-mode costume.

---

## D1. When does a policy refusal become an escalation?

### As built

The refusal side is exactly as the plan describes. A broker denial reaches
the model as an ordinary in-band error: `refusal_outcome`
(`packages/tools/src/tools/tool.gleam:746`) renders the denial with its
wanted grants attached as structured details via `denial_to_json`
(`packages/tools/src/tools/tool.gleam:793`), and nothing in production
consumes those details. The raiser exists — `raise_escalation_for`
(`packages/runtime/src/runtime/api.gleam:1063`) writes a durable record
scoped to the exact call — but its only callers are the demo, through the
unscoped legacy `raise_escalation`
(`packages/client/src/client/demo.gleam:252`), and the simulation surface
(`packages/conformance/src/conformance/simulation/surface.gleam:548`). The
machinery beneath is real and hardened: `clear_tool_call`
(`packages/runtime/src/runtime/strand_runtime.gleam:1460`) filters approved
records by exact `CallScope`
(`packages/runtime/src/runtime/escalation.gleam:74`) and consumes before
clearing (`consume_escalations`,
`packages/runtime/src/runtime/strand_runtime.gleam:1554`), with the
two-directional fail-safe the plan notes: a lost consume race drops the
grants, a crash after consumption spends the grant without executing.

Two things the framing does not say, and both matter more than the
question it asks.

**First: a scoped approval is spendable only if the refused call is
re-cleared, and production never re-clears.** The consume-before-clear
path loads a grant only for the clearance whose durable coordinates
`{operation, strand, step, source index, call id}` match the record. Those
coordinates recur only when the driver resolves the *same* planned call
again — which happens on replan after a restart, never after the call has
settled. Production settles every policy refusal: the denial surfaces
inside the tool run, after clearance, and comes back as a completed result.
The one caller that ever spends a scoped approval is the simulation, and
look at what it has to do: `escalation_dance`
(`packages/conformance/src/conformance/simulation/surface.gleam:498`)
raises, approves, and then **kills its own driver** instead of returning a
clearance, precisely so that recovery re-clears the same durable
coordinates with the approval in place. A model that reads the in-band
refusal and retries does not help either: the retry is a new call id, and
the exact attribution that the M3 fix wave installed (`RT-esc-attribution`,
`docs/review/m3-triage.md:44`) guarantees the approval cannot match it.
Exact scoping and retry-spendability are in direct tension; the design
resolved the security half and left the liveness half unbuilt.

**Second: even a spent approval widens nothing, because the grants channel
is severed at the production wiring seam.** `ClearanceQuery`
(`packages/runtime/src/runtime/effects.gleam:130`) carries the consumed
grants, and its own doc comment says production wiring maps them onto the
tool's context. It does not. Production `clear`
(`packages/client/src/client/wiring.gleam:930`) checks registry membership
and returns, never touching the query's grants; `tool_context`
(`packages/client/src/client/wiring.gleam:1002`) builds `Ctx.grants` from
the static session config instead (`config.grants`,
`packages/client/src/client/wiring.gleam:1010`), which `serve` sets to the
empty list once at boot (`packages/client/src/client/serve.gleam:743`); and
`ToolRun` (`packages/runtime/src/runtime/effects.gleam:163`) had no grants
field at all, so the clearance-time grants *could not* reach the run-time
context without changing the runtime-internal effects seam. The seam is not
Part-1 frozen, so the fix needs no protocol-change proposal — but until it
lands, any raising policy whatsoever is theater: a raised, approved,
consumed escalation changes no composed policy. The tool side is ready and
waiting — `bash` already passes `ctx.grants` into its broker call
(`packages/tools/src/tools/bash.gleam:141`); the break is exactly one seam
wide. WP-J 15's `grants: []` in code mode is not a code-mode quirk; it is
the same severed channel, one seam over.

### The question under the question

So "when does a refusal become an escalation?" decomposes into two
questions the option list runs together:

1. **When is a record raised?** Cheap, safe, answerable now.
2. **How is an approval ever spent?** This is what actually blocks issue
   #4, and it has three coherent mechanisms, none of which is built:
   - **Park and re-clear.** The driver, on a policy refusal that carries
     wanted grants, raises the scoped record and holds the call open
     instead of settling it; approval triggers re-clearance of the same
     coordinates, which is exactly what the tested consume-before-clear
     machinery was shaped for. Deny (or a decision timeout) settles the
     in-band error and the model routes around. No frozen interface
     changes — the machine already models an in-flight tool effect — but
     it needs a driver-side wait, a timeout policy, and a surface that
     prompts someone.
   - **Widen the session and let the model retry.** Design §5.3's own
     second sentence: "Approve similar for this session widens the session
     policy explicitly, never silently"
     (`docs/loom-design.md:253`). An approval writes a durable session
     grant; the model's natural retry — new call id and all — succeeds
     under the widened policy. Spendable without parking anything; needs
     grants read at dispatch rather than captured in a boot-time closure.
   - **Host re-executes.** The documented semantics of the unscoped path
     (`raise_escalation`, `packages/runtime/src/runtime/api.gleam:1636`):
     an explicit `consume_escalation` by a host that re-runs the denied
     action itself. The demo does this today. It spends, but nothing in
     the session loop benefits.

### The options, steelmanned

**(a) Never.** The strongest version is not "delete dead code" — it is
that in-band refusal genuinely is the better loop for an autonomous agent.
The model sees the exact policy diff, routes around it or asks in prose,
and no human is trained to rubber-stamp. This is the Codex-CLI lineage the
design claims for itself (`docs/loom-design.md:13`), and it matches
behavior as built, which the design priorities' "correctness" plank ought
to count for something. Against it: §5.3's first sentence specifies the
escalation flow outright; the approval machinery survived an adversarial
review precisely because it is meant to carry trust; the v0.1 milestone's
own definition ("some production path raises an escalation") forecloses
(a); and a session with no durable record of what the model wanted and was
refused has no audit trail for the single most security-relevant event
class it produces.

**(b) Always raise, keep the in-band error.** The strongest version
notices that the fatigue argument conflates *records* with
*interruptions*. Approval fatigue is a property of a blocking surface —
a modal prompt per denial — not of a durable row in a register. A record
that nobody is forced to look at is an audit line and a passive queue; the
gateway already surfaces escalation state as events for whatever client
cares. The loop-spam objection ("a record per refusal in a loop") has a
mechanical answer: `commit_raised` already refuses a duplicate id
(`runtime/api`), so a raiser that derives the id deterministically from
`{strand, tool, wanted-diff}` dedupes retries for free — the second
identical denial finds its record already pending.

**(c) Raise under an interactive session policy only.** The strongest
version: a pending record can only change an outcome in useful time when a
human is attached, so a headless run raising records is writing mail to
nobody, and the flag honestly encodes that. Against it: the premise is
wrong once records are deduplicated and non-blocking — a headless run's
records are exactly the ones the operator reviews *afterwards*, which is
what an audit trail is for — and the flag buys this non-benefit at the
price of a second code path through the most security-sensitive seam in
the runtime, tested separately forever.

### Verdict

**Raising: (b), with deterministic ids.** Every policy refusal raises a
scoped record and the in-band error stands. Whether any record interrupts
a human is a client-surface decision — which records get pushed versus
listed — and belongs in the gateway's consumers, where it can change
without touching the runtime. That is the true content of (c), relocated
to where it costs nothing.

**Spending — the actual release work in #4:** thread the grants channel
(`ClearanceQuery` grants into `ToolRun` into `Ctx`; runtime-internal), and
wire mechanism 2, session widening on approval, which is already
specified in §5.3 and is spendable without new machine behavior: the
model's own retry completes the loop. Defer parking (mechanism 1) until an
interactive surface exists that wants a blocking prompt; the scoped
consume-before-clear machinery stays tested and becomes load-bearing the
day parking lands. Issue #4's "Done" line — "an operator approval is
consumed by that exact call's clearance" — describes the parked flow and
should be revised to match, or #4 will be un-demonstrable as written.

### What would change it

If v0.1 is meant to *demo* blocking human-in-the-loop approval — a TUI
prompt at the moment of refusal — then parking is the release work after
all, and (c)'s session flag returns as a runtime concern, because a parked
call in a headless session is a hang. And if observation shows models do
not retry after an in-band refusal (making session-widening useless in
practice), the host-re-execute path is the honest minimum and (b)'s
records become audit-only. Both are empirical questions; the first belongs
to the owner, the second to a transcript grep after a few weeks of real
use.

### What did change it, and what shipped

The owner answered the first question: v0.1 *does* demo blocking
human-in-the-loop approval (#11, closed as decided). So the conditional
above fired and the recommendation inverted. Session widening was **not**
built. What shipped under #4, in the order the advisory said each step
was inert without the one before it:

1. The grants channel, as specified here — `ClearanceQuery` grants into
   `ToolRun.grants` into `Ctx.grants`. `wiring.Config` lost its
   session-wide grant list entirely, which is the same finding read from
   the other side: an unattributable grant must widen nothing.
2. **Parking** (mechanism 1), in `client/escalate`: a policy refusal
   raises, holds the call on its own effect process, and re-clears it
   once under the widened policy when the approval lands.
3. The raiser, with the deterministic `{strand, tool, wanted-diff}` id
   this note proposed, and (c)'s interactive flag back as a runtime
   concern deciding *parking only* — never whether a record is written.

The advisory's central finding held: an approval could not be spent, and
a raiser alone would have accomplished nothing.

---

## D2. Promote the citation checker to error level?

### As built, and the census re-run

`scripts/doc_check.sh` runs in both gate jobs via `make doc-check`;
citation findings are warnings, everything structural is already error.
Re-running it today gives **472 cited, 444 resolve, 151 symbol-checked, 72
drifted** — the plan's numbers within one, so the census is stable, not
growing. One hundred citation findings in all (resolution failures plus
drift): 95 in `docs/review/**`, five outside it.

The plan's recommendation — exempt `docs/review/**`, promote the rest —
was the thing to test, so I examined all five survivors. They are not a
backlog of four fixes. They are:

- **Two checker false positives from rhetoric.** `docs/loom-design.md:198`
  and `docs/architecture/messaging.md:12` both illustrate ghost state with
  a fictional message — "found the bug at ⟨auth file⟩ line 42" — and the
  checker's citation regex matches it, bare prose or not. The file does
  not exist because it was never meant to. At error level, correct and
  deliberate prose fails the build.
- **One checker misread.** `docs/code-tour.md:1282` cites
  `packages/client/src/client_ffi.erl:102`, and the claim is *still
  exactly right* — `code_change`
  (`packages/client/src/client_ffi.erl:102`) sits at that line today. The
  checker flags it because the nearest backticked span before the citation
  is `gen_server`, an atom that never appears in the file. The prose is
  correct; its word order fails the heuristic.
- **Two real drifts, both in the code tour.** `docs/code-tour.md:536`
  cites `settle_assistant` at a line it has left (now
  `packages/machine/src/machine/planner.gleam:1223`), and
  `docs/code-tour.md:1099` cites a result-register write that has moved
  several hundred lines.

### The options, steelmanned

**(a) Stay a warning.** The census that found all this *was* the warning
tier working; and the gen_server case proves on day one that error level
invites the classic lint pathology — reordering correct prose to appease a
heuristic. A checker that makes writers serve it has inverted the
relationship.

**(c) Clear all 72, then promote everything.** The review documents are
not dead weight: this plan itself argues from them, and a reader chasing
`RT-esc-attribution` (`docs/review/m3-triage.md:44`) through its citations
lands on wrong lines with nothing marking the document as historical.
Honesty argues for making them checkable, not exempt.

**(b) Exempt review, promote the rest.** Review documents are point-in-time
findings; re-pinning them to today's tree destroys exactly the property —
"what the reviewer saw at that commit" — that gives them evidentiary
value. (c) is not "most honest"; for these documents it is actively
falsifying, and the plan is right to reject it.

### Verdict

**(b), with three amendments before the promotion, in one branch:**

1. **Check only backticked citations.** Outside `docs/review/**` the only
   bare-prose citations in the tree are the two rhetorical examples, so
   the rule costs zero coverage today and removes both false positives on
   principle rather than by whack-a-mole: backticks are how these
   documents already distinguish "a real path in this tree" from prose.
2. **Exempt `docs/review/**` from the error tier but keep it in the
   warning census** — drift there is information about how far the tree
   has moved, not a defect. The stronger variant of (c)'s instinct is
   available cheaply later: a `Reviewed-at: <sha>` header the checker
   honors by resolving that document's citations via `git show` — four
   review documents already record their commit informally — but that is
   an improvement, not a precondition, and should not block the
   promotion.
3. **Fix the two code-tour drifts, and reorder the one `client_ffi`
   sentence** so the symbol nearest the citation is `code_change`. Two
   real edits, one cosmetic one.

Then errors hold the non-review corpus at zero, and the staleness warning
plus `/doc-gardening` keep servicing the review-document census as the
work queue it was always meant to be.

### What would change it

If the warning census were demonstrably being consulted — drift fixed
within days of appearing — error level would buy little and (a) would do.
Seventy-two accumulated drifts say it is not. In the other direction: if
backtick-only checking turns out to skip real citations in future docs
(writers citing bare paths out of habit), the rule should flip from
"check backticked only" to "flag bare citations as style" rather than
silently ignoring them.

---

## D3. Per-execution cgroup limits: accept the gap, or build delegation?

### As built, with one correction and one new finding

The mechanism is as described. `Detect`
(`packages/sandbox/internal/cgroup/cgroup.go:56`) takes the helper's own
cgroup as the base, probing only that it can create a child there; `Setup`
(`packages/sandbox/internal/cgroup/cgroup.go:102`) writes `memory.max` and
`pids.max` into a per-exec child, which works only if the base already
lists those controllers in its `cgroup.subtree_control`. The attach is
deliberately best-effort (`packages/sandbox/internal/jail/run.go:197`),
and the fork-bomb probe is a declared `known-gap` in
`.github/enforcement-expectations`, whose own header calls that "a
deliberate reduction in what CI proves".

**The correction:** the brief's "memory.max/pids.max appear structurally
unreachable outside the root cgroup" is true of the current *strategy*,
not of cgroup v2. The no-internal-process rule forbids enabling
controllers on a cgroup that has member processes; the helper's own cgroup
always contains at least the helper, so "base = own cgroup" is
indeed dead on every systemd host. But any **delegated cgroup that
contains no processes** distributes controllers to its children — that is
what delegation is for. systemd produces exactly that shape natively
(`Delegate=yes`, and on v254+ `DelegateSubgroup=`, which parks the
service's own processes in a subgroup and leaves the delegated root
empty), and an operator or CI job can produce it with three lines of
shell. Limits are not root-only; they are
delegated-and-empty-base-only, and that shape is orderable from the host.
This matters because it converts option (b) from "ask operators for an
exotic favor" into "consume the standard delegation contract".

**The new finding, which raises the stakes:** the gap is *silent at the
strict tier*. `FullEnforcement`'s contract
(`EnforcementDemand`, `packages/broker/src/broker/exec.gleam:91`) is that
any layer the policy called for and the helper did not apply refuses the
result — the settle path keys on `skip:` entries
(`packages/broker/src/broker/exec.gleam:762`). But when no cgroup
attaches, `enforcementEntries`
(`packages/sandbox/internal/jail/run.go:376`) merely omits `cgroup-v2`
from the list; it emits no `skip:` entry, and the `degraded` bool tracks
only the bwrap layer. So a policy that demands memory and pid ceilings
passes `FullEnforcement` with those ceilings unenforced, on every host
that cannot delegate — which today is every production-shaped host. That
is silent widening, the exact category the security review's SEC-H2 calls
"the one thing the design forbids" (`docs/review/triage.md:19`), and it
contradicts the sandbox's own doctrine, "Degraded means degraded, out
loud" (`packages/sandbox/CLAUDE.md:129`).

### The options, steelmanned

**(a) Accept it.** The ceilings are the third tier of defense: wall-clock
timeout, output caps, and pgroup `SIGKILL` bound every execution already,
and a fork bomb dies at the deadline with its group. Phase-1 shipped on
that argument. Documenting "mem/pids are best-effort absent delegation" is
one honest paragraph, not an engineering project, and M2's row can read
done with the claim narrowed. The plan itself allows that "the answer may
legitimately be (a)".

**(b) Delegation as configuration.** The design's first priority is
security and isolation; a *named enforcement layer* that no production
shape can engage fails that priority in the way the enforcement-
expectations file exists to make visible. With the base handed in, the
jail job can delegate a real cgroup and move the fork-bomb probe from
`known-gap` to `required` — CI then proves the production shape rather
than the root-cgroup counterfactual the supplementary step currently
prints and fences off (`.github/workflows/ci.yml`, "Supplementary" step).
The build is small: a `--cgroup-base` flag or environment variable,
`Detect` preferring it (verify it is empty of processes, enable the
controllers in its `subtree_control`, report honestly when absent), and a
documented systemd shape.

**(c) Broker-side placement.** The steelman is thin: the broker spawns the
helper and could place it first. But the broker lives in the same
populated cgroup and needs the same operator-granted delegation before it
can place anything, so (c) is (b) with the `mkdir` moved across the trust
boundary into the Gleam VM — gaining nothing, and installing a kernel
concern on the side of the boundary the design keeps kernel-free. It is a
false alternative, not a real option.

### Verdict

Two decisions were filed as one.

1. **The honesty patch is not optional, and is release scope.** When the
   policy asks for mem or pids and no cgroup attached, the helper must
   emit a `skip:` entry so `FullEnforcement` refuses. This follows from
   the design's own priority order and doctrine independently of any
   delegation decision; it is a few lines in the helper and one test.
2. **Then (b).** Take the base as configuration, document the systemd
   shape, and wire `jail-linux` to delegate a base so the probe becomes
   `required`. M2 then reads done with nothing narrowed. If (b) slips,
   the fallback is (a) plus the honesty patch, with the claim narrowed in
   `packages/sandbox/CLAUDE.md` and design §5.2 — honest, but strictly
   worse than a build measured in days.

Sequencing note: the honesty patch makes every strict-tier mem/pids
policy go from silently unenforced to loudly refused on hosts that cannot
delegate. That is correct behavior and it is disruptive — which is the
argument for landing the patch and (b) in the same release, not for
skipping the patch.

### What would change it

A named deployment story that cannot delegate — a container platform in
the actual target set that provides no cgroup v2 delegation — would make
(b) a path nobody runs, and (a)-plus-patch the end state rather than the
fallback. Nothing in the design docs names one today. In the other
direction, if `FullEnforcement`-with-limits turns out to have production
callers before (b) lands, the patch alone will refuse them, and the
schedule pressure flips to (b) immediately.

---

## D4. Are WP-J 15 and 16 in WP-N's scope?

### As built

The spec is explicit twice over: WP-J 15 and 16 "are in scope only if the
owner puts them there", and, one sentence earlier, they "are the plumbing
this seam leans on hardest"
(`docs/loom-implementation-spec.md:399`). Both entries check out in code.

**WP-J 15** (`docs/spec-gaps.md:616`): every clearance the code-mode
pipeline makes passes empty grants — `grants: []` at the build call
(`packages/codemode/src/codemode/build.gleam:292`), the node launch
(`packages/codemode/src/codemode/launch.gleam:706`), the launch policy
composition (`packages/codemode/src/codemode/launch.gleam:821`), and the
cap router (`packages/codemode/src/codemode/satellite.gleam:1204`). An
approved escalation widens nothing, and it fails closed.

**WP-J 16** (`docs/spec-gaps.md:624`): identity and budget are specified
in three places — `ExecConfig`
(`packages/codemode/src/codemode/codemode.gleam:74`) has the caller
assemble `BuildConfig`
(`packages/codemode/src/codemode/build.gleam:93`), `SatelliteConfig`
(`packages/codemode/src/codemode/satellite.gleam:319`), and `ExecId`
(`packages/codemode/src/codemode/satellite.gleam:176`), each carrying its
own operation, step, and budget. The broker opens one ledger per
`{op_id, step_id}` (`packages/broker/src/broker/budget.gleam:11`), and the
e2e builds under `step_id <> "-build"`
(`packages/codemode/test/codemode/e2e_test.gleam:316`), opening a second
ledger against the same `Budget` value. One nuance the entry undersells:
the build/run split looks deliberate — different phase, different policy,
different enforcement report — and build and run are sequential, so the
doubled outstanding cap is latent rather than live. The defect is not that
two ledgers exist; it is that *nothing types how many identities a caller
may mint*, so the third, accidental one is a copy-paste away.

One more as-built fact reshapes the decision: the plan has **already**
routed WP-J 15 into release issue #4, whose "Done" includes "a code-mode
execution re-run under an approved escalation actually carries the
grants". So D4 as posed is really only deciding WP-J 16 — unless #4 is
trimmed, which D1's findings argue it should be.

### The cases

**For WP-N owning them:** the orchestration seam is the first thing anyone
runs unattended, and the spec's own words make 15 and 16 its hardest-leaned
plumbing. Threading one identity before a second seam multiplies the
callers is the cheap moment; threading grants into `ExecConfig` is best
designed once, when both seams exist to constrain it.

**Against:** WP-N's exit list is already long, and its "must not" section
shows a seam being defended against growth. WP-J 16 is a behavior-free
refactor any branch could take; WP-J 15 is blocked on a decision (D1's
spend mechanism), and parking undecidable work inside a work package turns
the package into the queue for the decision.

### Verdict

**Split them; both land near WP-N but differently.**

- **WP-J 16: yes — as WP-N's first commit** (or an immediately preceding
  branch). It is exactly the refactor whose cost grows with every caller,
  and WP-N adds the largest new caller the pipeline will ever get. Restate
  the invariant while doing it: not "one identity ever" — the e2e's build
  split is legitimate and the tests rely on it — but *one threaded
  `ExecIdentity` from which the build phase is derived*, one parent
  budget, phases named in the type, so that no caller can mint a third
  identity and the ledger count per execution is a property of the types.
  That is the entry's own "would make it unbreakable" sentence, minus the
  implication that the `-build` ledger is itself the bug.
- **WP-J 15: yes to WP-N, and out of issue #4.** It is D1's spend
  mechanism applied to the code-mode pipeline and cannot be specified
  until that mechanism is chosen — a re-run "carrying the grants" means
  grants threaded into `ExecConfig` and composed at
  `packages/codemode/src/codemode/launch.gleam:821`, and *when* a re-run
  happens is precisely D1's open half. The v0.1 milestone's escalation
  claim ("some production path raises an escalation") is fully satisfied
  by the workspace tool path; keeping the code-mode half in #4 couples a
  release blocker to an unmade decision. One correction feeding this: the
  plan's #4 says both M2's and M4's Part-4 notes cite the raiser gap. M2's
  note does (`docs/loom-implementation-spec.md:496`); M4's Part-4 note
  does not — the M4-side citation lives in the WP-J gap log. The release
  argument for the code-mode half is weaker than the plan implies, which
  is one more reason it can wait for WP-N.

### What would change it

If D1 resolves to parking (mechanism 1) *in the release*, then the re-run
machinery exists before WP-N starts, WP-J 15 shrinks to "thread grants
into `ExecConfig`", and pulling it back into the milestone becomes cheap
enough to reconsider. And if WP-N's schedule slips far enough that other
code-mode work (issue #13's cap modules) arrives first, WP-J 16 should
land with *that* work instead — its correct position is "before the next
caller", wherever that caller comes from.

---

## Where D1 and D4 meet

They are one decision surface touched at two seams. The grants channel —
approval to consumed record to composed policy — is severed in the
workspace tool path at `clear`
(`packages/client/src/client/wiring.gleam:930`) and never opened in the
code-mode path (WP-J 15's four `grants: []` sites). D1's verdict re-threads
the first; WP-J 15 is the same re-threading at the second, and both sit
downstream of D1's single open question, the spend mechanism. Decide the
mechanism once, in D1; apply it to the tool path in the release (#4);
apply it to code mode in WP-N (D4). The order is forced: doing WP-J 15
first would mean choosing the spend mechanism implicitly, inside a work
package, for the seam with the higher blast radius.

---

## Corrections to the brief

Findings above, gathered for the record; the first three change
conclusions, the rest are calibration.

1. **"Nothing consumes them" understates it.** Below the missing raiser,
   the production wiring drops clearance-time grants entirely
   (`packages/client/src/client/wiring.gleam:930` ignores them,
   `packages/client/src/client/serve.gleam:743` pins session grants
   empty, and `ToolRun` cannot carry them), and `ClearanceQuery`'s doc
   comment claims a mapping that does not exist. The approval flow is not
   merely unreachable; reached, it would be inert.
2. **"Four HIGH bugs" is two plus two.** The adversarial review's
   escalation section carries four HIGHs, but two of them
   (`RT-restart-leak`, `RT-await-aba`, `docs/review/m3-triage.md:46`) are
   strand-lifecycle bugs filed under the same heading; the approval flow
   proper had two (`RT-esc-attribution`, `RT-esc-double`), both verified
   fixed in the current tree.
3. **"Structurally unreachable outside the root cgroup" is
   strategy-relative.** Any delegated, process-empty cgroup works; the
   root is merely the one cgroup exempt from arranging that. See D3.
4. **Census drift:** today's run reports 472/444/151/72 against the
   brief's 463/435/150/70 and the plan's 473/444/151/72 — stable, and the
   plan's figures are the accurate ones.
5. **"Backlog of about four":** five findings outside `docs/review/**`,
   of which three are checker false positives and two are real drift.
6. **Issue #4's M4 citation:** M2's Part-4 note cites the raiser gap;
   M4's Part-4 note does not (the WP-J gap log does).
