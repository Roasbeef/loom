# 079: Registered deployment and immutable generations

Status: approved 2026-10-06; option B and the history/system-generation amendment are
accepted. Implementation and executable acceptance pending.

Numbering note (2026-10-07): this approved proposal was originally numbered 077. It is renumbered 079 because current main already assigns 077 to web peer links. Approval and normative requirements are unchanged.
The distributed image compatibility label remains `org.loom.distributed.protocol=077`; it is a retained compatibility token, not the current document number.

## Problem

The ordinary daemon cannot yet create and reopen Registered sessions through its default
tools while the checkout exists only on the executor. Full physical Close permanently
fences one service generation, so reopen must create a proved clean successor without
replacing the old immutable owner doors. Sixteen lifetime hot rows would exhaust normal
clean reopen after sixteen uses, and ordinary service routing cannot retrieve a retained
result after that generation is fenced.

## Decision

Use one immutable deployment Table for listener authority and session assembly. Pin one
canonical enrollment in the durable owner companion before activation. Each generation
has its original owner-use UUID, Broker, custodian and service doors. Close/archive
retires the entire physical generation; reopen/restore admits exactly g+1 from complete
original executor and owner close records, with unchanged Binding, descriptor and
enrollment. Resident detach keeps its existing running generation.

The owner retains provider credentials, conversation/catalogue/domain state, approvals,
pooled budgets and blobs. One retained companion serves the session; each live
generation has one original owner custodian and one Broker.

Managed endpoints have sixteen global live/unretired slots and permanent history capped
at 4096 generation identities and 256 MiB logical metadata. Exact retirement, permanent
tombstone, original removal ACK and Removed COMMIT/readback precede slot reuse. Original
fenced/removed results remain accessible through one independent history lane. Complete
ToolKey, ChildOrigin, system intent and LSP identity links route all evidence to its
original generation.

This contract amends protocol 067 only at these named surfaces. Protocol 078 defines the
required LSP attachment. Existing Compile attempts, native retirement, enrollment,
original credit accounting and authority epochs remain obligations. C1-C3, mobility,
automatic failover and workspace snapshot migration are outside this slice. Declarative
states, byte/count limits and acceptance controls below are normative.

## Administrative deployment and first activation

Add `client/daemon/deployment` and `executor/remote/scope_admin`. They expose closed
provisioning. Existing `server.WorkspaceAuthority.resolve/revalidate` remain unchanged
(`packages/client/src/client/daemon/server.gleam`). Both listener routing and
`manager.Assembly.build` capture the **same immutable validated Table**; today these are
constructed separately (`daemon/main.gleam`).

Example deployment, with illustrative public identities and pins:

```toml
schema = 1
endpoint_lifetime = "retired_slots_v1"
owner = "owner-a"
local_node = "owner@owner.example.invalid"
[membership]
ca = "/etc/loom-owner/ca.pem"
certificate = "/etc/loom-owner/cert.pem"
key = "/etc/loom-owner/key.pem"
cookie = "/etc/loom-owner/.erlang.cookie"
options = "/etc/loom-owner/tls.options"
[[peers]]
node = "exec@executor.example.invalid"
leaf_sha256 = "1111111111111111111111111111111111111111111111111111111111111111"
[[workspaces]]
executor = "exec-a"
workspace = "project-a"
peer = "exec@executor.example.invalid"
workspace_epoch = 1
session_epoch = 1
first_generation = 1
generation_policy = "clean_successor"
descriptor_sha256 = "2222222222222222222222222222222222222222222222222222222222222222"
```

`loomd --deployment /etc/loom-owner/deployment.toml` selects this file. The shipped
release launcher loads and validates it before VM boot, writes/verifies the private
fixed TLS options, and uses `distribution.bootstrap_home/boot_arguments`; `daemon/main`
loads the same validated bytes, calls `distribution.start`, then resolves each installed
`Peer`. `loom-executor --deployment ...` uses the same boot procedure. Starting
membership in an already ordinarily booted VM refuses (`distribution.gleam`). Clients
supply no credential paths. Registration protects
`distribution.protected_membership_paths`, including the canonical options file.

The executor file adds helper/pool settings, a private state root and at most 32
workspace descriptors. Each descriptor contains selector/owner/epochs/first generation
and the existing `NativeFacts`, `CodeModeFacts`, compilation contract and approved LSP
profile declarations. Load them through total strict decoders, reject unknown/duplicate
keys, then canonicalize and check all physical roots/toolchains/protected regions **on
the executor at boot**. `registration.new` checks at most 16 working roots and the full
policy (`registration.gleam`); enrollment checks separation and bounded content
(`broker/enrollment.gleam`). Describe performs no later checkout mutation or probing.

Reuse membership's 1..32 peers, 3..255-byte ASCII node names and exact 32-byte pins
(`distribution.gleam`), selector's 1..128-byte labels and positive signed-32-bit epochs
(`core/workspace.gleam`), and endpoint's generation/wait validation
(`beam_endpoint.gleam`). Owner/executor labels use the selector grammar. Descriptor
bytes use enrollment's existing 256-KiB codec envelope and 196,608-byte text preflight
(`broker/enrollment.gleam`). Deployment input is at most 8 MiB before TOML parsing;
structured validation caps rows/fields before constructing a table.

```gleam
pub opaque type Table
pub opaque type Selected
pub opaque type PinnedEnrollment

pub fn load(path: String) -> Result(Table, DeploymentError)
pub fn authority(table: Table) -> server.WorkspaceAuthority
pub fn select(table: Table, retained: workspace.RegisteredBinding)
  -> Result(Selected, DeploymentError)
pub fn revalidate(table: Table, pin: PinnedEnrollment)
  -> Result(Nil, DeploymentError)

pub opaque type GenerationKey
pub opaque type GenerationAssociation
pub opaque type RetirementRecord
pub type AdminRequest {
  Describe(session: ids.SessionId, binding: workspace.RegisteredBinding,
    descriptor: String)
  Activate(association: GenerationAssociation, commands: OwnerCommands)
  ObserveGeneration(key: GenerationKey)
  CloseGeneration(key: GenerationKey)
}

```

Digest strings are validated SHA-256 spellings. The shared node endpoint receives this
named administrative attachment separately from tool Submit. Only its configured owner
Peer may use it. Describe selects an installed descriptor and purely derives the exact
session-scoped enrollment/registration digests; the snapshot already includes its
session UUID (`enrollment.gleam`). Its reply names full scope, descriptor digest,
canonical enrollment bytes, enrollment SHA-256 and authorized generation policy; it
grants no generation claim. It starts no journal, helper, service, lease or preparation,
and reserves no persistent scope slot.

Allow four outstanding admin exchanges, each under the existing 100..30,000-ms endpoint
wait. Bound control envelopes by the existing 256-KiB framing profile; enrollment
travels as its separately checked bounded content. The node reserves at most 2 MiB of
aggregate response capacity before mailbox admission: four exchanges, each with one
256-KiB control envelope and one 256-KiB enrollment body. Activation history uses
`executor_scope_admin.sqlite`, format 1, named generated SQL and total decoders. Its
exact-generation associations, closing fences and retirement records are append-only;
four bounded administrative requests share reserved response capacity. Activation is
keyed by the exact generation association and predecessor proofs below. Describe
allocates no durable identity.

## Durable owner pin and authority at every effect

Use `<state_root>/remote-custody/<session_uuid>.sqlite`, mode-private parent,
independent of catalogue display paths, executor root spellings and live PIDs. Add
format 6 to `storage/owner_custody`, whose current format is 5 (`owner_custody.gleam`).
Add `owner_custody_enrollment(singleton=1, schema=1, session_id, binding, descriptor_digest, enrollment_digest, enrollment_bytes)` in the companion schema, with
named `insert_owner_enrollment`, `owner_enrollment_header` and `owner_enrollment_body`
SQL. **Generation is absent from this immutable singleton.** Canonical Binding bytes use
the existing total workspace codec. One immutable row is charged once against the
companion's existing byte quota, including framing; it creates no tool/child identity.

```gleam
pub fn pin_enrollment(store: Store, pin: EnrollmentPin)
  -> Result(PinReadback, Error)
pub fn read_enrollment(store: Store) -> Result(EnrollmentPin, Error)
```

`storage.EnrollmentPin` is a bounded opaque metadata envelope over core Binding, digests
and bytes. Storage verifies its canonical envelope and digest through the existing
injected SHA-256; it imports neither broker nor client. Client `PinnedEnrollment`
additionally contains the decoded SessionEnrollment and is constructed only after exact
Selected/Describe equality, canonical `enrollment.decode`, scope/registration/contract
checks and injected host SHA-256 verification. Read scalar size/schema fields before
materializing the bounded body, recheck canonical bytes/digest and all metadata on every
reopen. Existing `enrollment.matches` rejects even drift beneath unchanged digest claims
(`enrollment.gleam`).

Format-5 local companions receive only a transactional additive migration; existing
reports/fences remain unchanged. A preexisting registered companion without a pin
refuses fresh work. No adoption of today's enrollment repairs missing historical
metadata.

Creation retains catalogue Binding first, obtains Describe, writes the enrollment pin
with SQLite FULL synchronization, reads it back, and then commits/reads the first exact
generation association before Activate. Physical session consumers start only after
exact activation acknowledgement. The companion exists before the first tool; failed
creation retains its original Binding. Custodian boot decodes and verifies the full
pinned association before exposing admission, using the existing host-validation pattern
rather than a new storage dependency. Close preserves the file; archive metadata retains
its stable UUID association; restore uses that same file. Compaction retains report
references and their companion association. Transcript export alone is insufficient
(`067`).

`deployment.authority(table)` resolves selectors to exact Binding and revalidates
retained epochs. That same table supplies `select` to assembly. Changing the file does
not revoke a running VM. Revocation applies the existing exact endpoint/native fence and
owner admission fence before replacing administration; a new boot cannot silently
upgrade a retained Binding.

Each Fresh tool runner, named system effect and nested physical capability calls
`deployment.revalidate(table, pin)` before clearance/send. Semantic Submit, native
admission and LSP admission independently validate their actual executor
registration/scope/generation. Hello grants no cached authority; the executor checks
actual admission. Partition before admission yields unavailable/uncertain within the
original bound, never owner-local execution; partition after possible admission retains
original identity and uncertainty. Historical report/transcript reads remain available
without fresh executor authority (`067`).

## Closed physical assembly and concrete caller changes

Select the Binding branch before owner settings resolution. Owner provider/admin
configuration may be read in either branch; only LocalPhysical resolves local
helper/toolchain/Git/guidance/home/temp/workspace filesystem facts. Current
`resolve_managed` refuses registered assembly (`serve.gleam`).

```gleam
pub type PhysicalPlan {
  LocalPhysical(LocalFacts)
  RegisteredPhysical(RegisteredFacts)
}
pub opaque type RegisteredFacts
pub type CommandTarget {
  LocalCommand(root: String)
  RegisteredCommand(scope: workspace.Scope, enrolled: SessionEnrollment)
}
```

`RegisteredFacts` owns pin, Selected/table projection, an exact-generation endpoint
Config and immutable scoped service adapters. Executor strings cannot construct
LocalWorkspace. Settings replaces `workspace`, `helper_path`, `helper_pool_size`,
`demand`, `base_policy`, physical `home` and `codemode_seed` with `physical: PhysicalPlan`; existing provider/secret/store/settings fields remain owner-owned. Rename
owner HOME used for administrative extension/config lookup to `administrative_home`;
registered workspace guidance comes from the executor. Owner blob root derives from
owner session state, never from enrollment.

`wiring.Config.workspace: String` becomes existing `tool.WorkspaceAccess`;
`tool_context` passes that value, replacing its unconditional local constructor
(`wiring.gleam`). `tools.Ctx` already has the correct closed workspace plus separate
OwnerBlobs and needs **no new field** (`tool.gleam`). Native command adapters receive
`CommandTarget` in trusted constructors, not in Ctx. Project scope, original
ToolKey/ChildOrigin, command coordinates and service doors per run; never capture all
Settings in a retained closure.

`tools/codemode.Request.workspace: String` becomes `WorkspaceAccess`; `request(mode, ctx, source, within_ms, on:)` copies it without `require_local_workspace`
(`tools/codemode.gleam`). `client/codemode.Config` replaces physical
work/socket/seed/toolchain fields with a closed `ExecutionPlacement { LocalExecution(LocalExecutionFacts) RegisteredExecution(RegisteredExecutionFacts) }`.
The registered constructor retains enrollment, remote CompileService/Launcher and
workspace/search/rename/LSP doors; it uses `execute_managed(config, parent, request)`
(`client/codemode.gleam`). Placement dispatch occurs after pure vetting but **before**
root preparation (`client/codemode.gleam`). Registered cleanup never calls owner
directory removal on executor paths.

| Actual caller | Contract change |
| --- | --- |
| `contributions.built_in` | Add closed `PhysicalTools { LocalTools RegisteredTools(adapters) }`; registered fs constructors use `workspace_tools.Service`, preserving cap/job/blob virtual schemes and complete Ctx. |
| Bash Foreground/Auto, jobs | Add `bash.registered_tool(jobs, target)`; share current decoding, permissions, timeout/mode and jobs actor. `jobs.Wiring.workspace` becomes CommandTarget. All native requests use one original Broker and enrollment cwd/environment. |
| Native grep, code-mode search/fs | Add `grep.workspace_tool(service)` over closed semantic requests. Bind code-mode fs/search/rename through workspace_client with original admitted capability ordinal; no local rg/filesystem fallback. |
| Goal checks/imported hooks | `goalcheck.Runner.workspace` and `hookrunner.Context.workspace` become CommandTarget. Trusted named system children use the same dispatch binding/Broker. Registered hook discovery uses executor semantic guidance plus owner administrative sources, never `hookserve.locations(owner_home, executor_root)`. Hook output never exposes owner transcript/credential paths as executor paths. |
| Startup Git/guidance/probe/LSP | Executor supplies real `with_git/with_guidance/with_initialization` callbacks (`workspace_local.gleam`). Owner uses Guidance/Initialize/Git and preserves `session_git` starting revision. Approved opaque LSP OwnerDoors attach to ordinary tools, diagnostics, rename and code mode; missing required LSP attachment refuses full-product activation. |

Jobs/checks/hooks currently rebuild local calls from Settings (`serve.gleam`). All
remain acceptance scope; registered paths never enter owner
stat/mkdir/canonicalize/cleanup.

## Owner custody and report admission

Before runtime admission, pin the companion, allocate the custodian address, build one
remote dispatcher/Broker, install the fixed per-session ToolConfig, start the supervised
custodian and activate that exact executor generation. ToolConfig supplies small
immutable runner projections. `config_with_reports/new/supervised` remain the custodian
lifecycle APIs (`custodian.gleam`), extended with mandatory registered-pin verification
for registered boot.

Fresh runner execution receives the original incarnation-pinned Handle.
Compile/Launch/workspace bindings derive from that Handle; an external reclaimable
address cannot become runner report authority. `dispatch_binding.with_commands` pins
enrollment and preserves one original Broker; no tool fixture assembles another Broker.
Trusted registry assembly selects `OrdinaryFinal` versus `CodeModeReportV1` before
admission, preserving clearance/declaration metadata and the **17,301,648-byte**
complete report allowance (`storage/owner_custody.gleam`). Provider names/arguments
cannot choose profiles. Install `code_reports.retained_tool`, SHA-256 and
`codemode.over_reports` for the same owner/session.

Add `instance_owner.RemoteCustody` after Runtime/ToolConfig/Services/Broker and all
remote work drain, before Storage/Namespace (`instance_owner.gleam`). Registered
Services cleanup invokes CloseGeneration and awaits the executor physical-close record
while the original Broker/custodian/OwnerCommands doors remain live. Broker then
drains/stops; RemoteCustody awaits the original custodian/task stop and records the
combined close proof. No cleanup callback depends on a stopped Broker. Persist the
original owner-join observations after custodian stop through the serialized companion
DAL, before releasing Storage/Namespace. Missing witnesses block clean retirement and
preserve companion/journal custody. It never resolves a replacement runner or treats
actor DOWN as report settlement.

## Full executor host and lifecycle

Preserve native-only `host.Provisioning`; add closed `host.FullProvisioning` and
`configure_full`, implemented through the same temporary host owner.  `configure_full`
compares every scope/enrollment/native-handle association; construction starts nothing
and grants no command authority. Standalone `executor.boot` remains local: it starts its
own Broker (`executor.gleam`) and cannot be the unchanged remote entrypoint.

```gleam
pub type FullProvisioning {
  FullProvisioning(
    node: NodeScope,
    enrolled: SessionEnrollment,
    registration: registration.Registration,
    journals: JournalProvisioning,
    physical: ScopedNativeProvisioning,
    semantic: workspace_local.Host,
    compilation: service_input.CompilationContract,
    lsp: ApprovedLspProvisioning,
    drain_ms: Int,
  )
}
pub fn configure_full(provisioning: FullProvisioning)
  -> Result(Config, Error)
```

`NodeScope` is opaque and retains the original endpoint/owner Peer/labels/generation.
`JournalProvisioning` names three private paths plus their existing checked Limits;
`ScopedNativeProvisioning` contains the current helper SpawnConfig, pool size and
retirement seam. `ApprovedLspProvisioning` is the protocol-078 opaque attachment, not a
callback factory. `Config` internally becomes NativeScope or FullScope; existing
`start/supervised/close` operate on either and preserve native-only callers.

Git/Initialize callbacks require an actual owner-clearance door, not an executor-local
Broker stub. Add a named `OwnerCommands` administrative attachment to Activate, built
from the original Broker/custodian. Its closed methods accept the complete retained
Workspace invocation and a checked fixed Git/Initialize command template; the owner
verifies the original semantic input, ChildOrigin, enrollment mapping and exact CallSpec
before its ordinary native reservation/clearance path. The executor gets only that bound
scoped door. It grants no second Broker or replay authority. Existing `GitHost` already
retains Invocation specifically for owner clearance (`workspace_local.gleam`). LSP uses
its separate OwnerDoors contract for its command family.

Dependency/order: node TLS/shared endpoint/admin table -> owner pin COMMIT -> Activate
original claim -> one scoped pool and broker/executor native handle -> native
journal/service -> workspace/resource journals -> concrete semantic callbacks/service ->
Compile+Launch over the **same native Service and resource Journal** -> approved LSP
Host/OwnerDoors -> `compile_registration`, `attach_launch`, named LSP attachment ->
publish one row LAST (`beam_endpoint.gleam`). Executor callback execution uses owner-cleared offers through the owner Broker; it creates no executor-local approval
authority. LSP profile/probe/preparation access is supplied only by its approved
contract.

Use staged typed ownership in the existing weft actor/state-machine host, with
prepare/publish/begin ordering. Before publication, rollback closes independently
acquired resources in reverse dependency order. After a lost publication reply, exact
fencing precedes reconciliation; startup failure preserves original journal/claim
identities. Scope shutdown fences, quiesces, drains endpoint credits while reply
producers remain live, joins workspace/Compile/Launch/LSP work, proves physical-resource
cleanup and original native retirement, observes service exits, then releases journals.
Attempt native cleanup even when transport drain fails.

`close` of a service or SQLite actor alone isn't these witnesses
(`workspace_service.gleam`, `compile_service.gleam`, `launch_service.gleam`,
`resource_journal.gleam`). Missing evidence retains journals and the charged slot. No
new monitored ledger, timer loop, poll implementation, dependency or FFI is needed.

## Full Close and immutable successors

Session Close/archive performs full physical generation shutdown. Resident detach
continues the existing runtime. Reopen/restore creates fresh work only through an
explicitly admitted successor generation, with unchanged Binding, descriptor and
canonical enrollment. This keeps protocol 078's permanent registration/slot-input fence
unchanged (`078-registered-lsp.md`). The old Host never receives replacement callbacks:
`workspace_local.Host` retains concrete doors (`workspace_local.gleam`), and
dispatch_binding retains the original custodian (`dispatch_binding.gleam`).

`GenerationKey` is `(full scope, descriptor digest, positive signed-32-bit generation)`.
`GenerationAssociation` additionally binds enrollment digest, original owner-use UUID
and checked predecessor pair (node-retirement digest and owner-close digest), or the
closed FirstGeneration variant. The owner-use UUID is minted once per association and
identifies its immutable Broker/custodian/door bundle; it is never reused for another
live owner. The boot table authorizes `CleanSuccessor(first_generation)` only for the
exact same selector/epochs/descriptor/pin and **g+1** after a checked g retirement.
First generation must equal the configured value; exhaustion at 2,147,483,647 refuses.
Clients supply no generation or retirement evidence.

Add companion tables `owner_generation_associations` and `owner_generation_closes`,
keyed by exact GenerationKey, plus a write-once ToolKey-to-generation association
committed with fresh tool admission. Named queries insert/read association
headers/bodies, insert/read close records, and resolve an original tool's generation.
Exact canonical bytes and digest participate in conflict checks. Charge both tables
against the existing companion byte quota before insertion. On each open, owner pin
verification and association COMMIT/readback precede Activate; cancellation or reply
loss never replaces that association. Recovery routes each old tool/service/native/LSP
identity through its original association, never through a latest-generation lookup. Old
report references remain attached to the session companion.

The node ledger uses the same keys and canonical association bytes. Its vocabulary is
`Claimed -> Publishing -> Published -> Closing -> Retired`, or sticky Unknown; the
managed endpoint permits `Retired -> Removed` while preserving every permanent record.
Closing can precede any claim. No row recovery returns a new startup claim. A duplicate
Activate observes exactly its original row, owner-use UUID and live door addresses; a
changed bundle conflicts. A recovered Published/Claimed row with unavailable original
custody is Unknown. ObserveGeneration is historical metadata observation, not Activate.

CloseGeneration accepts an exact key even before Activate. The serialized node writer
commits a permanent closing fence before any acknowledgement; when no startup claim
existed, it records `NeverStarted`, which forever refuses the delayed first Activate for
that key. A prior claim means admitted original startup: Close joins/cleans that
original owner and can report Retired only afterward. It cannot turn a pending startup
into NeverStarted or manufacture a replacement. Physical constructors remain gated by
their sole live claim; publication is last.

The node-admin actor is the **sole managed-generation publisher and fencer**. Full-host
startup presents its original claim and concrete row for publication; the actor rechecks
the durable generation state before forwarding register. It COMMITs Publishing before
sending register; an interrupted Publishing disposition is Unknown, never proof of
absence. It sends register/fence in order from the same process, retaining the existing
ordering guarantee (`host.gleam`, `beam_endpoint.gleam`). Close commits Closing before
forwarding the fence, so a delayed publication request is refused.

A previously forwarded register precedes its fence. The native-only host API stays
unchanged. Administrative timeouts retain original uncertainty and cannot mint another
claim.

`RetirementRecord` has two closed variants. `NeverStarted` requires the durable no-claim
closing fence and no physical startup. Owner assembly joins are retained separately.
`StartedRetired` requires one closed endpoint witness: PublishedFencedDrained with no
original assigned/unusable credit, or UnpublishedFenced whose durable Claimed-to-Closing
transition proves Publishing was never authorized. Both require
workspace/Compile/Launch/LSP continuation joins; exact physical-resource cleanup; native
scope retirement and its covered-key confirmations; original service exits; journal-handle closure; and original host owner normal exit **after** its successful retirement
result.

The owner counterpart also requires runtime/effect, Broker and custodian/task joins
before successor construction; physical Close runs while the original doors remain live.
DOWN alone, timeout, census, lost reply, report COMMIT, a generic service close or a
recovered Claim satisfies none of these requirements. The current native close already
preserves its original disposition and covered-key confirmation (`service.gleam`); full-host composition must expose a checked record after the remaining witnesses.

The node COMMITs the executor RetirementRecord before returning its digest. The owner
combines that exact record with its original joins in a separate GenerationCloseRecord;
both digests bind the successor association. The node compares its own stored
predecessor record, and receives the configured owner Peer's exact canonical close
attestation. No provider/request constructor can assert that attestation. The owner
verifies the exact association, COMMITs and reads back that record plus its own original
joins, then constructs the successor association.

Missing proof after actor death remains Unknown, even if cleanup probably occurred. Only
a complete original record permits g+1. It never upgrades enrollment, refreshes old
deadlines, replays uncertain effects or automatically replaces a dead executor.
Successor journals live under `<executor_state>/scopes/<session_uuid>/generations/<g>/`,
independently bound to that association; old journals stay sealed/readable. Existing
native `close_epoch` is permanent (`journal.gleam`); successors cannot reopen it as live
authority.

Each successor constructs fresh physical services/journals and immutable owner doors.
Its registry row names g+1 exactly. Old runners retain their original incarnation-pinned
handle and original doors through drainage; subsequent history remains read-only under
their original association. No mutable callback swap, registry resolution to a new
Broker, automatic attachment resurrection or latest-generation fallback is introduced.

## Endpoint capacity and original removal

Keep sixteen global live/unretired slots (including unpublished/uncertain startup
claims) and the existing six transport credits. After COMMIT/readback of an exact
StartedRetired record with PublishedFencedDrained and a permanent tombstone,
`retire_registration(server, exact_row, record)` checks Fenced+Drained again and removes
only the retired concrete service/monitor references from the hot table. It never
reconstructs a credit, deletes history or reopens that generation. The permanent
association/fence/retirement tombstone remains in the durable node ledger. Only after
the original endpoint acknowledges exact hot-row removal does the node COMMIT a Removed
disposition; slot reuse requires that committed disposition.

NeverStarted authorizes no startup and releases no live claim slot. A claimed
unpublished startup uses StartedRetired with UnpublishedFenced plus all original
startup/resource joins; only that durable proof permits Removed without endpoint
removal, since Publishing was never authorized. Unknown/assigned/unusable scopes keep
their slot. `register_generation` requires the original predecessor record, one
committed successor claim and no live same-Scope generation; every
request/close/observation names an exact generation.

The history ledger has fixed ceilings of 4,096 permanent generation identities and 256
MiB of logical metadata, reusing the established journal maxima
(`resource_journal.gleam`). Reserve its row/byte capacity before every first identity
insertion, including no-claim Close, and before authorizing a claim; no eviction or
reuse of old identities. A full ledger refuses additional opens explicitly. This
supports repeated routine clean opens beyond sixteen without retaining retired physical
handles, but still advertises finite lifetime history capacity. It makes no unlimited
disk/WAL/memory claim. Old tool/report evidence retains its existing independent quotas
and files.

The concrete durable provenance boundary is metadata-only
`executor/generation_scope_plan.Plan`. It retains the complete original
association/enrollment, configured owner Peer, actual native capacity,
workspace/resource journal paths and selected existing Limits. LSP provenance is
closed DisabledLsp for an accepted empty declaration table, or EnabledLsp with
its original custody path, selected Limits, contract and complete ordered
one-through-sixteen profile/root inventory. Disabled provenance supplies no LSP
recovery inputs and does not fabricate an enabled profile.

The original header and canonical enrollment are separately capped at 262144
bytes and independently bounded/decoded. Their domain-separated digest binds
both exact lengths and bodies. The permanent parent reservation includes both
actual body lengths plus the 32-byte digest: at most 524320 added logical bytes
per planned identity, excluding existing parent reservations and SQL/VM overhead.
The same-database child table is `generation_scope_plan`;
`generation_registry.admit_planned` inserts and reads back both parent and child
in the first claim transaction. COMMIT precedes StartupClaim issuance. The narrow
`scope_plan(Store, GenerationKey)` method observes metadata only. These local
methods add no external wire or deployment configuration surface.

The format-two additive upgrade checks the entire original format-one bounded
scalar/body inventory before migration or uncertainty changes, within the same
transaction. It adds no provenance to old identities, retains every original
reservation, and creates no claim. Missing legacy provenance remains unavailable
for full-product history. Legacy admission/native component APIs remain valid;
full-product scope_admin later uses planned admission exclusively. No selected
production quota defaults or managed DAL acquisition are established by this
storage boundary.

The managed endpoint APIs are:

```gleam
pub type EndpointLifetime { RetiredSlots16 }
pub fn configure_managed_server(store: generation_registry.Store,
  within_ms: Int, lifetime: EndpointLifetime) -> Result(ServerConfig, Error)
pub fn register_generation(server: Server, row: Registration,
  claim: generation_registry.StartupClaim) -> Result(Nil, Error)
pub fn retire_registration(server: Server, row: Registration,
  retired: RetirementRecord) -> Result(Nil, Error)
```

The concrete implementation uses `generation_registry.Store` for the conceptual
ledger handle. Three narrow local construction/check seams preserve the publication
ordering: `beam_endpoint.publication_endpoint(Server, Registration)` derives the
row-bound original endpoint digest;
`generation_registry.validate_publication(Store, StartupClaim, Digest)` checks the
actual private Store actor/incarnation, exact association/doors and committed Publishing
intent; `generation_registry.validate_removal(Store, RetirementRecord, Digest)` checks
the exact committed published retirement record and its original endpoint. These checks
grant no claim or replacement credit, and add no external wire or configuration surface.

The endpoint digest binds its fresh nonce, canonical full Binding, owner Peer, all
concrete service PIDs and original lifetime owner. Existing PID projections and inspect
spellings identify only this original endpoint lifetime, never durable replacement
lookup. An attached Compile owner must match the full canonical enrollment digest.
Checked native-only registrations can exercise component controls; full-product
`scope_admin` retains the obligation to assemble complete Compile/Launch/LSP services and
verify exact enrollment at full provisioning.

Actual successful hot-row removal and its acknowledgement receipt share one actor
transition after the real Fenced+Drained recheck. The endpoint retains a metadata-only
exact receipt dictionary, capped at 4096 entries, containing one 32-byte retirement
digest and one 32-byte row-bound original endpoint digest per permanent ledger identity.
That is at most 262144 logical digest bytes, excluding map/VM overhead; a smaller
configured ledger ceiling bounds reachable entries further. No physical handle or
monitor is retained. An absent hot row without this exact receipt refuses; lost ACK
reconciliation repeats only the same committed record against its original endpoint.

`generation_registry` owns the bounded SQL/total codec layer and opaque first-claim/retirement values; it imports neither host nor endpoint. `scope_admin` composes
that ledger, host and endpoint. Construction of these values follows durable admission
or actual witness validation, never a public unchecked constructor. The node-wide
endpoint_lifetime is included in every immutable descriptor digest; mixed lifetime modes
on one shared endpoint refuse configuration. Registered full-product deployment selects
RetiredSlots16; mixed endpoint modes refuse before activation.

The retired hot-row removal changes only managed-generation servers. Their closed
bootstrap mode enables the new publication API; ordinary legacy `register` cannot bypass
the managed ledger. Initial and successor publication are both gated by that ledger. Old
wire headers can match no live row after retirement and never select g+1. Bounded
administrative ObserveGeneration reads only the original association/close record.

Full retained results use the independent exact-generation history attachment below;
they never rebuild a physical host. Crash or reply loss between retirement COMMIT,
endpoint removal and Removed COMMIT keeps the slot charged and refuses successors.
Reconciliation can repeat only the same removal against the original endpoint
incarnation and full original retirement record; an absent row on a replacement endpoint
is no proof. A missing/unusable original credit prohibits removal. Node-admin/endpoint
death grants no renewal; explicit recovery must validate committed records, and
uncertain originals stay charged/fenced.

This decision supersedes only protocol 067's sixteen **lifetime in-memory rows** and
prohibition on deleting the hot row for managed servers. Permanent generation admission
fences, original credit accounting, original enrollment, authority epochs and no
automatic restart remain. The approved capacity model is sixteen live/unretired slots
with permanent bounded history.

## Exact-generation history attachment

`journal.recover`, `workspace_journal.recover` and `resource_journal.recover` are local
DAL APIs. Owner missing-receipt recovery uses ordinary Query (`compile_client.gleam`,
`launch_client.gleam`, `workspace_client.gleam`), which rejects fenced rows
(`beam_endpoint.gleam`). Add these closed operations beside administrative activation,
independent of registration service routing:

```gleam
pub opaque type OriginalHistoryRequest
pub opaque type HistoryValue
pub opaque type HistoryReceipt
pub type HistoryObservation {
  Missing
  Unknown
  Retained(value: HistoryValue)
}
pub type HistoryRequest {
  ReadHistory(generation: GenerationKey, original: OriginalHistoryRequest)
  AcknowledgeHistory(generation: GenerationKey,
    original: OriginalHistoryRequest, result_digest: BitArray)
}
pub fn read_history(config: HistoryConfig, key: GenerationKey,
  original: OriginalHistoryRequest) -> Result(HistoryObservation, Error)
pub fn acknowledge_history(config: HistoryConfig,
  receipt: HistoryReceipt) -> Result(Nil, Error)
```

`OriginalHistoryRequest` has exactly Native, Workspace, Compile, Launch, LspLease,
LspInvocation and LspCommand constructors, checked through their existing or
protocol-078 total codecs. Native retains full key, Prepared digest and original
canonical request; Workspace retains the complete Invocation; Compile/Launch retain
complete ServiceKey and canonical input; LSP retains the complete original lease/timed
invocation/command parent, request/offer and digests. They cannot be reconstructed from
an abbreviated address or current-generation lookup. `HistoryValue` contains one
original family record and references to its separately retained associations; it
recursively fetches none. It contains no attachment, Claim, listener, artifact issuance
authority or replacement native association.

Authenticate the configured original owner Peer. Compare full GenerationKey, retained
enrollment/descriptor digests and exact original request against the node's permanent
association. Resolve journal paths and Limits **only from that association**, never
caller strings or a live row. Generation g remains addressable after its fence and
Removed record. Neither stale live authority nor g+1 grants access to another owner.

Already committed owner receipts remain locally readable without this exchange. Owner
Compile/Launch/workspace/native recovery selects its exact persisted generation link:
live observation may use that original endpoint, while fenced/retired history uses this
attachment. Neither branch resolves a current generation.

The node owns **one history exchange lane globally**, with immediate Busy refusal and no
detached queue. It does not consume, release or reconstruct any of the six original
effect credits. One existing weft managed run bounds authentication, DAL, transfer and
release together to the configured 100..30,000-ms administrative wait. A timeout ends
only that observation; it renews no execution or original grace deadline.

After full Close has released service journal handles, the lane temporarily opens only
the requested family's original DAL using the existing Recover entrypoints and retained
scope/enrollment/quotas. Resource recovery additionally receives the same temporarily
recovered native journal. Each opened journal retains its original row/byte/decoded
inventory ceilings; history does not weaken them or load other families eagerly. Use
only `inspect`, `payloads`, `inspect_compile`, `inspect_launch` and exact receipt
operations; release temporary handles in reverse order before releasing the lane. LSP
uses its protocol-078 custody DAL's inspection/receipt operations.

No Fresh, admit, reserve, claim, preparation, host, helper, service restart or physical
effect is called. Frozen phases and recovery's existing Unknown treatment remain
unchanged. For a generation whose original handles have not been proved released, refuse
with Unknown instead of opening a competing recovery owner. Missing/corrupt/incomplete
evidence yields Missing/Unknown or a fixed validation error, never reconstructed records
or a definite execution refusal. Failed DAL release keeps the lane unavailable until the
original run joins; it grants no capacity or successor proof.

The owner validates identity, canonical full result and family digest, then uses
existing owner child/service receipt or LSP receipt DAL operations. It COMMITs and reads
back the exact receipt plus its generation link before constructing opaque
`HistoryReceipt`; only that value can send ACK. The node reopens the same original DAL
and checks the exact retained result digest before applying existing receipt semantics:
workspace `acknowledge` (`workspace_journal.gleam`), resource
`acknowledge_compile/launch`, native `ConfirmOwnerReceipt` (`admission.gleam`), or the
protocol-078 LSP exact receipt. Native receipt content is the original retained
output/terminal inventory, validated by the existing native receipt scanner; its
terminal digest is checked separately before the frozen native event. Missing output is
not fabricated from retirement. ACK loss permits repeating only this exact original ACK.
Receipt cannot establish transport/native/resource retirement or free a charged
generation slot.

### Full content accounting

History metadata uses the existing 256-KiB control profile. Full content uses the
consumed 64-KiB chunk transfer, with a distinct closed history direction bound to
`(GenerationKey, family, original address, input digest, result digest, exchange correlation)`. Add only the needed fixed directions to `workspace_transfer`; preserve
its declared-size, hash, ordinal and consumption checks. Per-family preflight/canonical
codecs remain mandatory:

| Family | Full content profile preserved |
| --- | --- |
| Native | Original request/Prepared at most 131,072 bytes; native wire metadata at most 262,144. At most 64 output records, each 16,384 bytes and 1,048,576 aggregate; terminal at most 32,768. Canonical complete receipt uses the existing 2,097,152-byte scanner (`launch_receipt.gleam`; `payload.gleam`). No generic MessagePack limit is substituted for it. |
| Workspace | Invocation 9,437,184; completion 33,554,432 (`workspace_codec.gleam`), with its existing request-matched completion decoder. |
| Compile/Launch | Complete service input envelope 9,437,184, including actual header/enrollment/source (`codemode/service_input.gleam`); outer completion 262,144 through their closed completion codecs. Associated native evidence follows the native profile above, without losing its distinct receipt. |
| LSP | Preserve protocol 078's complete lease/command custody and finite input/result profiles: finite envelope 139,268 / 4,473,092 bytes, 8192-byte identity header, bounded Search projection/terminal/offer, and exact timing/parent fields. No JSON-RPC transcript is invented. The LSP attachment is approved by protocol 078. |

Reserve input **and full result**, metadata and framing before admission, at both ends.
The largest pair is workspace's 42,991,616 content bytes. Its 144 input plus 512 result
chunks add `2*41 + 656*9 = 5,986` framing bytes; reserve two 256-KiB control bodies and
two 1024-byte route headers independently. Including the existing receiver's possible
chunk-plus-joined-binary duplication, the single lane reserves **86,515,554 logical byte
slots per end**, 173,031,108 across owner and node, for these binary inventories, and
its existing per-family decoded node/string/container budgets independently. Content is
released before the next exchange.

VM/distribution/SQLite overhead is not claimed equal to this logical reservation. The
four-admin/2-MiB metadata reservation is separate and cannot carry a full result.
Complete CodeModeReportV1 owner retention keeps its 17,301,648-byte allowance; history
does not downgrade its profile.

## Original system and LSP generation links

Each admission link covers **complete existing ChildOrigin**, in addition to the parent
ToolKey link when present. SystemChild is `(session, service, ordinal)` and has no
ToolKey (`core/remote_tool.gleam`); neither its stored request nor semantic Scope
supplies generation. Add `owner_child_generation(address PK, canonical_origin, generation_key, enrollment_digest, original_request_id, input_digest)` in the same
companion transaction as existing `admit_child`, `admit_workspace_child` and applicable
service/offer/command reservation. Compare canonical origin, generation and original
payload/ID on every retry/readback. Tool children also compare the parent ToolKey link.
No synthetic ToolKey, latest-generation routing or inference from missing links is
permitted.

For system allocation, add named SQL tables `owner_system_intent(intent_address PK, generation_key, service, operation, step, request_id UNIQUE, intent_bytes)` and
`owner_system_ordinal(service PK, next_ordinal)`. The intent address is the trusted
caller's **already durable work address** plus exact generation and fixed service.
Startup uses `(generation, closed startup phase)`; checks/hooks use their retained run
address; post-write uses the original write/request address. A caller without such an
address must retain its ordinary work intent before this API. Providers cannot choose a
service or invent a new intent on retry.

```gleam
pub fn retain_system_intent(store: Store, intent: SystemIntent)
  -> Result(IntentReadback, Error)
pub type SystemReservationPayload {
  NativeSystem(Payload)
  WorkspaceSystem(WorkspaceRequest)
}
pub fn admit_system_child(store: Store, intent: IntentReadback,
  build: fn(ChildOrigin, ids.EntryId)
    -> Result(SystemReservationPayload, Error))
  -> Result(SystemReservationReadback, Error)
```

`retain_system_intent` COMMITs/readbacks one original UUID and full intent, returning
that original on an exact retry. It reserves the eventual child slot and bounded
intent/link metadata against existing companion and per-parent quotas; subsequent child
admission transfers that slot rather than charging it twice. Counter rows belong to the
fixed trusted service inventory and their metadata is charged too. It grants no effect
permission. `admit_system_child` first requires the original live generation admission,
then runs one serialized SQLite transaction: look up the intent's existing child first;
otherwise read its service counter, validate the existing 0..4095 ordinal bound
(`remote_tool.gleam`), construct the real SystemChild, build canonical payload using the
retained UUID, reserve existing child/result byte capacity, insert child plus generation
link, associate the intent and increment the counter, then COMMIT/readback all fields.

The callback is the trusted client's pure family encoder and executes no effects. The
closed payload variant preserves existing native versus full-workspace reservation
profiles. Named SQL performs lookup, counter compare/update, insert intent-child
association, link insertion and exact readback. Existing 64 children per parent and
companion row/byte quotas still apply (`owner_custody.gleam`); no reset, wrap, eviction
or new quota is introduced.

Only the successful original live Fresh transaction can return sendable reservation
authority. Exact retries return Retained observation, never Fresh; unknown COMMIT/reply
loss requires original intent/child readback and no replacement allocation. Changing
bytes, service, generation or original ID conflicts. New work after reopen uses g+1's
distinct stable intent but the **same lifetime service counter**. An old intent always
resolves g. Existing callers build native/workspace envelopes from that exact origin;
their codecs and ordinary single-effect claim rules remain unchanged.

LSP lease and finite invocation have separate original identities. Add
generation_key/enrollment_digest columns to their owner `lsp_lease`, `lsp_finite` and
`lsp_command` rows, committed atomically with each first original reservation in that
same LSP database. A command compares its exact lease/invocation parent's generation; an
admitted tool/child reference compares the companion link. LSP receipt references
include that generation, and both existing readbacks precede ACK. Preserve protocol
078's cross-store commit order, slot pointer and timing/nonce rules. Lost replies
inspect the original row; they do not allocate a lease incarnation, invocation or system
ordinal. No mutable lease attachment or ordinal-zero restart is introduced.

## Compatibility with ordinary local behavior

Per-strand shell cwd remains a checked per-invocation/default value carried alongside
CommandTarget, separate from workspace authority. Local cwd keeps ordinary local
filesystem behavior. Registered cwd is checked against its retained executor workspace
authority and is sent through the original enrolled command path; no executor path
enters owner stat, canonicalization or cleanup. Changing cwd cannot construct
LocalWorkspace or widen the admitted roots. Existing default/omitted-scope LSP inference
must survive the physical-plan dispatch and moved manager assembly. These are caller
compatibility requirements, not new wire operations.

Catalogue migrations must preserve both recent-folder and registered-workspace binding
histories. Reconcile the existing competing version claims in migration order; a version
number alone cannot stand in for either schema's presence. The companion's format-6
additive enrollment migration remains separate from catalogue versioning. Existing local
tests, imports and behavior remain part of the gate.

## Acceptance

Drive shipped owner and full-executor entrypoints on separate hosts, with the checkout
absent from owner disk and owner canaries proving absence of physical fallback. Ordinary
authenticated create/open, fs/search, Bash Foreground/Auto, jobs, goal checks, hooks,
Git/guidance/initialization, real Compile/Launch, full LSP, rename and observation must
work. Verify one original Broker per generation and complete 17,301,648-byte
CodeModeReportV1 retention. Execute all protocol-078 acceptance controls.

Close before the first tool, clean Close/reopen, archive/restore and compaction retain
the same enrollment and reports. Fresh work uses exactly g+1 with new immutable doors.
Exercise delayed Activate after no-claim Close, duplicate old Close after g+1, changed
owner doors, lost Activate/publication/retirement/removal ACK, cancellation during
startup, stale epochs, partition, and executor/node-admin death. Assert exact original
routing, no renewed old effect, no owner fallback and independently retained cleanup
witnesses. Sixteen unresolved/live slots refuse excess while more than sixteen
sequential clean opens across sessions succeed. Finite permanent history exhaustion
refuses explicitly. Sibling scopes and shared credits remain usable where their original
custody permits.

Lose a retained full workspace result, Close/remove g, reopen g+1, then ReadHistory g
and COMMIT/readback/ACK its exact result. Exercise the 33,554,432-byte result boundary,
incorrect digest, ACK loss and malformed/oversized framing. Assert zero helper or
physical-host startup, unchanged g+1 request counts, no effect-credit reconstruction,
one bounded history lane and exact lane release. Repeat native, Compile, Launch and LSP
family receipt controls with their distinct full-content profiles.

Retain tool-free startup workspace work and a separate LSP lease/invocation before clean
Close/reopen. Fresh startup receives a greater durable system ordinal and g+1 links;
history reads recover the original g operations. Lose intent/reservation COMMIT replies
and retain the original UUID/ordinal/generation with no second effect. Changed
generation/content conflicts. Existing child/ordinal quotas refuse without reset.
Exercise ordinary local per-strand cwd and default LSP inference, plus Registered cwd
with no owner-side physical path access.

## Costs and implementation boundaries

Sixteen lifetime hot rows were considered. They preserve finite endpoint inventory but
exhaust after sixteen total opens. The selected model removes only proved-retired
physical/monitor references, preserving a finite permanent identity ledger. Unknown
custody keeps capacity charged. History adds one bounded content lane with separate
logical reservations; deployment adds strict startup configuration and stable owner
pinning. None establishes aggregate physical filesystem quota or unlimited lifetime
capacity.

Use named SQL and total codecs; generated SQL artifacts have their own commit. Compose
full-host ownership through the existing weft primitives. Preserve existing tests,
dependencies, native-only host callers and ordinary LocalPhysical behavior. Add no FFI.
Component gates, full repository gate, hosted CI and shipped separate-host acceptance
remain distinct evidence; approved APIs do not establish any implementation outcome.


## Addendum: native identity beneath a workspace request

Approved October 7, 2026. The retained semantic Invocation and its cleared
native command have different immutable payloads. Reusing their child address
would conflict in owner custody. A derived identity preserves their original
relationship without allocating another system ordinal or adding an effect
before Broker clearance.

Git/Initialize native execution beneath an admitted semantic Workspace invocation
MUST use an explicit derived workspace-command identity. The identity contains the
complete original semantic ChildOrigin and a closed command phase. Its parent MUST
be a direct ToolChild with Workspace(n), or a direct actual SystemChild allocated
through the original system-intent transaction. Derived commands MUST NOT parent
other derived commands. Compile, Launch, legacy Capability and unrelated roles MUST
NOT construct this identity. An admitted capability SemanticWorkspace child uses its
existing exact-name/exact-ordinal NativeCommand counterpart instead of this wrapper.

The constructor creates identity data only. It MUST NOT allocate an ordinal, clear a
command, grant send permission or resolve a latest generation. Its address MUST be
disjoint from the original semantic child's address and encode the original parent
address plus the closed phase. Its canonical encoding MUST preserve the complete
parent, including any real ToolKey's argument digest and result-entry identity, or the
actual system service and lifetime ordinal. A distinct public fields variant MUST
expose this derivation; it MUST NOT project as direct ToolFields or SystemFields.

The derived child MUST share the original semantic parent's quota group. Its native
request, terminal allowance, canonical origin and generation link are charged against
the existing companion quotas and the same 64-children bound. A system-derived command
MUST NOT mint another system ordinal or reset the existing service counter. Pending
original system intents continue to count against that same bound.

Before clearance, OwnerCommands MUST resolve the original semantic parent from its
retained request UUID, check canonical Invocation equality, and check the exact
original scope, operation, step, generation association and enrollment digest. The
original system service or ToolKey provenance MUST come from retained typed data,
never from command text, source-index defaults or a parsed address. Only a live
original owner admission can proceed.

Before any native send, the owner MUST atomically compare the original retained
semantic parent UUID/input digest and original generation/enrollment association,
refuse a cancelled/frozen parent, reserve the native request/result capacity, and
COMMIT/read back the whole post-clearance native envelope plus its canonical origin
and generation link. The envelope MUST preserve owner/full binding, actual physical
operation/step, parent UUID/input digest, closed phase, and exact complete Prepared.
The owner MUST compare the actual Prepared with the actual Broker-cleared Dispatch
and the enrollment-derived fixed command template. The executor independently checks
its actual registration, scope, generation, policy ceiling and admission deadline.

Retry MUST resolve the original identity and bytes. Retained observation, unknown
COMMIT, a lost reply or history read MUST NOT re-clear, refresh deadlines, mint a
replacement UUID or grant another Submit. Cancellation MUST retain the exact derived
identity, including before a native UUID exists, and fence later admission. Matching
late native evidence remains retainable under the original UUID and Prepared digest;
it does not authorize replay or establish physical retirement. Complete native
receipt COMMIT/readback precedes DurableReceipt. The outer semantic completion and
native receipt remain separate original evidence.

The closed command phases are GitBranch, GitRepositoryProbe, GitRevision,
GitStatus, GitWorkingTreeDiff, GitStagedDiff, GitSinceRevisionDiff and GitLog.
The owner selects the phase from the original retained Git query and its fixed
recipe; a peer cannot choose arbitrary argv or an integer subphase. Revision
and log-limit inputs remain in the original Invocation and are compared by
canonical bytes and digest. CurrentRevision may use the separate fixed
repository-probe and HEAD commands needed by the existing starting-baseline
behavior. A workspace initialization phase grants no command authority until
its concrete bounded recipe is specified by trusted full-host assembly. The
semantic Initialize label does not imply `git init` or require a native effect.

Add a checked pure constructor and a distinct fields variant for the derived
identity. Preserve every existing direct child encoding and address. The total
decoder MUST reject nested derivation before recursive construction and retain
the existing 8192-byte complete-identity ceiling. LSP/system-intent constructors
MUST continue to accept only their declared direct families. In particular,
`child_tool` returning an error is insufficient to classify a system origin;
callers MUST match the explicit direct SystemFields variant.

The owner resolves the semantic parent by its retained request UUID and checks
full canonical Invocation equality. No semantic wire change is needed to put
an omitted ChildOrigin into the executor callback. Existing canonical-origin
and payload columns can retain the new identity. Fresh native admission MUST
use a specialized same-transaction retained-parent check, not the generic
same-session check. Receipt readback keeps that immutable relation after
cancellation while granting no new execution.

This addendum covers commands beneath an already admitted semantic request.
A standalone NativeSystem intent has no such parent. Its separate original
identity must be reserved before Broker clearance, with exact post-clearance
payload admission afterward; that approved sequencing change is recorded
separately and must preserve lifetime counters, reserved capacity and original
COMMIT/readback semantics.


## Addendum: standalone native system reservation

Approved October 7, 2026. This amendment supersedes the single-transaction
origin/payload allocation order above for fresh NativeSystem work. WorkspaceSystem
keeps its existing pure family builder. The native path needs a real origin before
Broker clearance, while its actual Prepared bytes exist only after clearance.

For a standalone NativeSystem, the owner MUST retain its ordinary work intent
and exact original SystemIntent before clearance. It MUST then allocate the
original direct SystemChild in one serialized transaction, attaching its exact
canonical identity to that intent and advancing the lifetime service counter
once. COMMIT and exact readback MUST precede Broker clearance. This pending stage
MUST preserve the original UUID, operation, step, generation/enrollment association,
reserved child slot and bounded metadata; it grants no Submit authority and has
no invented native payload or generation link.

Only the original live FreshPending flow MAY clear through the original Broker
with this identity. It MUST use one retained command declaration and deadline.
After clearance, a specialized transaction MUST compare that pending identity and
intent, reject cancelled/historical work, retain the whole actual native envelope
and original child-generation link, and transfer existing reservations without
allocating another ordinal. Only its successful original live Fresh COMMIT and
full readback MAY produce sendable native reservation authority. Exact retries
and recovery MUST return observation, never Fresh or renewed clearance.

Unallocated intents reserve future ordinal capacity. All intents without an
admitted child, including allocated/cancelled pending intents, MUST continue to
reserve original per-parent and companion child capacity. Allocated origins MUST
NOT be counted twice against the ordinal bound. Cancellation, unknown COMMIT,
reply loss and recovery MUST NOT reclaim the original ordinal, discard its
charge, substitute another UUID, refresh a deadline or authorize replay. Format
validation MUST distinguish these states from admitted native/workspace rows,
and existing historical links MUST NOT be fabricated during migration.


### Original live permission through the Broker

A closed local `broker/dispatch.SystemReservationRef` retains the original direct
SystemChild and UUID, a fresh nonserializable BEAM Reference, and a typed subject
owned by the original pinned custodian. It has no codec or durable representation.
A closed reserve/cancel protocol carries bounded native envelope bytes and the
actual cleared request, operation, step, deadline and caller. It carries no
arbitrary callback or executable peer value.

The existing custodian creates one auxiliary typed subject selected into its
existing actor. Only an original Fresh allocation installs an opaque pending
value in its bounded live permission inventory and returns its reference. That
inventory MUST fit the already reserved companion child capacity and bounded
command declaration profile. History, duplicate allocation, reconnect and reboot
MUST NOT populate it. Original owner fencing and shutdown invalidate all entries;
they do not erase pending durable charges or prove physical closure.

The internal Dispatch handoff gains the explicit optional reference. A named
`clear_system_call_from` derives the origin from it and preserves both through
normal clearance in the same original Broker. Existing ordinary entrypoints carry
no reference; CallSpec remains unchanged. The static binding prepares the actual
Dispatch, checks exact Prepared/request/step equality, and invokes the original
reference's closed reservation method. It MUST verify the exact original subject,
not just its owner PID, and MUST NOT recover permission from an origin lookup.

The serialized custodian requires its original live admission, reference, caller,
complete declaration and generation. It consumes the actual retained pending
value before attempting native admission and publishes that consumed state on
every success or failure arm. Only the first actual Fresh admission can return
sendable reservation. A retained row, unknown COMMIT or lost reply cannot rearm
the permission. The original managed run and dispatcher retain caller lifetime;
this introduces no second actor, Broker, monitored-PID ledger or callback registry.

Cancellation retains this reference through pre-reservation cancel and abandon.
It serializes with admission on the original writer, cancelling the pending intent
or the admitted child as appropriate. Exact duplicate cancellation remains sticky.
Unallocated cancellation allocates and cancels the originally reserved ordinal in
one transaction; it does not add a reusable unallocated-cancelled state. A late
Dispatch either loses to the fence or remains the same already admitted original.
No late answer authorizes replacement clearance.

### Format seven and retained capacity

Reuse the existing nullable intent origin/address/profile columns with a closed
state decoder: unallocated, native_pending, native_cancelled, admitted native, or
admitted workspace. Pending states retain the full existing 2048-byte future
origin/link allowance until final admission. They hold no invented child row or
child-generation link. Final payload admission transfers the existing allowance
and child slot in the same transaction as the actual request and generation link.

This changes companion semantics from format six to seven even though no new
column is required. Migration MUST first validate the complete old format under
its old invariants, including refusal of new derived-child tags or pending states
in a format-six database. Then it transactionally advances the format without
backfilling missing historical links or creating live permission. Preserve the
existing validated format-five migration before this step. Unknown or corrupt
formats refuse unchanged.

Maintain distinct bounded inventories. Future ordinal capacity is the lifetime
counter plus unallocated intents only. Child capacity is actual children plus ALL
intents lacking an admitted child, including allocated or cancelled pending ones.
Derived workspace commands share that same original parent group. Allocation
neither counts an ordinal twice nor removes a pending child slot. Cancellation
and recovery never reset counters or reclaim these permanent charges.

### Ordinary callers

A goal check MUST retain and read back its actual Checking transition before
native admission; its register sequence can identify that original occurrence.
A failed write cannot launch a registered check. Imported hooks MUST retain their
actual event occurrence and trusted handler position, complete original stdin
and original deadline before constructing SystemIntent. Identical consecutive
hooks remain distinct events. A content hash, attribution operation or freshly
computed timeout cannot replace that durable work address. SystemIntent's
8192-byte metadata bound does not permit truncating the ordinary input or moving
unbounded content into control metadata. Local behavior remains unchanged where
this registered admission path is not selected.


## Addendum: original-writer Effects construction

The original owner can bind registered hooks to its actual runtime writer before
recovered drivers start. This is an assembly prerequisite; it does not select
registered operation in the shipped daemon or supply the missing FullHost.
Existing `Config`, `Options`, `Runtime`, `Effects`, `open` and `open_published`
shapes and ordinary behavior remain unchanged.

The following two assembly-only constructors are accepted:

```gleam
@internal
pub fn open_fact_effects_published(
  session: Session, base: Effects, options: Options,
  bind: fn(FactHandle) -> Result(Effects, String),
  publish: fn(Runtime) -> Result(Nil, String),
) -> Result(Runtime, String)

@internal
pub fn start_effects_published(
  build: fn(Address(writer.Message)) -> Result(#(Config, Effects), String),
  publish: fn(SessionTree, Effects) -> Result(Nil, String),
) -> Result(#(SessionTree, Effects), actor.StartError)
```

Session seeding and identity use the original base clock and entropy. The
supervisor allocates one namespace and its original drain, registry and writer
addresses. It invokes `build` once, before starting the root. API constructs the
private `FactHandle` from that actual writer address and invokes `bind` once.
Binding MUST perform no I/O, actor startup, fact access or fresh admission. The
finished Effects retain the base clock and entropy and supply every strand's
options, the publisher and the returned Runtime. Restart closures retain those
finished Effects, never `build` or `bind`.

The first existing root child publishes the actual root and direct drain
capability before registry, writer, factories or recovery start. Acknowledged
custody is required before subsequent children start. The writer address has no
live recipient during binding or publication. Construction cannot manufacture
fresh Checking work, hook occurrences, generation authority or system permission.
Build refusal disposes the original namespace. Publication refusal uses the
existing failed-root disposal. Successful startup preserves the existing root
and namespace unlink handoff and root-death namespace retention.

The independent construction review found that existing `wire_registered` starts
a counter actor; it cannot be called inside pure binding. Split that startup
from the shared pure gate wrappers. An opaque prepared registered gate retains
ONE original counter PID and Subject, acquired before opening. Its explicit
release requests that counter's stop and joins its actual normal exit; timeout,
abnormal exit or missing evidence refuses cleanup success. Legacy `wire` and
`wire_registered` keep their existing start-and-compose behavior and shared gate
reducers. No counter is rebuilt per strand or writer/factory restart.

Assembly publishes the prepared gate's complete release capability through the
existing original `instance_owner` Services boundary before opening. Refused
publication or refused opening must explicitly retire the acquired counter even
when the assembly owner remains alive. Successful opening retains it through the
Runtime drain, then retires it through Services cleanup. `instance_owner` already
orders Runtime before Services and blocks later cleanup on a failed release.
The runtime cleanup retains the projected SessionTree rather than the entire
Runtime or Effects graph. A lost opening reply after custody acknowledgement
leaves these original capabilities responsible for cleanup; it never authorizes
a second opener.

This refinement was accepted after the independent original-writer Effects
construction review and its counter-ownership correction, under the delegated
protocol review process in `docs/execution.md` section 7. These additive internal
constructors change no frozen Part-1 interface, storage schema, control envelope
or product policy. Implementation review and component gates remain required.
The separately pending weft Detached selector/pin and executor host-reader
dependency remain unapproved.
