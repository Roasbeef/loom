//// The identity one code-mode execution runs under, the approval that
//// widens it, and the phases derived from both.
////
//// # Why this module exists
////
//// The broker keys its pooled budget ledger by `{op_id, step_id}` — the
//// *batch* identity a token is valid for, and one ledger is opened per
//// live pair (`broker/budget`, and
//// `docs/adr/005-budget-pooling-granularity.md`, which fixes that keying
//// as a decision rather than a default). A caller who mints a second
//// identity therefore gets a second ledger: twice the `max_outstanding`
//// cap, and a second wall deadline, for one execution. That is an
//// amplification bypass, and amplification is what the pooling exists to
//// refuse.
////
//// Before this module the pipeline handed the caller three places to
//// write an identity — the build's configuration, the satellite host's,
//// and the run's own — each with its own operation, step and budget. The
//// two ledgers that produced were latent rather than live (build and run
//// are sequential, so the doubled cap was never two live caps at once),
//// but nothing *typed* how many identities a caller could mint, so a
//// third was a copy-paste away.
////
//// # The invariant, stated precisely
////
//// Not "one identity ever" — the build/run split is legitimate: different
//// phase, different policy, different enforcement report, and the
//// end-to-end deliberately accounts its hermetic build separately. The
//// invariant is **one threaded `ExecIdentity` from which the build phase
//// is derived**. Concretely:
////
//// - `ExecIdentity` is opaque, so `for_execution` is the only way to mint
////   one, and it is minted once per execution by whoever starts it.
//// - `PhaseIdentity` is opaque too, and the only ways to obtain one are
////   `build_phase` and `run_phase`, both of which take an `ExecIdentity`.
////   A phase identity is therefore always *derived*, never assembled.
//// - No configuration record in the pipeline carries an operation, a step
////   or a budget any more (`build.BuildConfig`, `satellite.SatelliteConfig`,
////   `launch.LaunchConfig`, `compile.CompileConfig`). The pipeline hands
////   the derived phase identity to the injected build, launch and router
////   seams at call time, so there is nowhere for a caller to put a second
////   one.
//// - `ledger_keys` is a total function of the `ExecIdentity` alone. How
////   many ledgers an execution opens is therefore readable off the
////   identity value before anything runs, and it is one or two — never
////   three, because `BuildLedger` has two variants and neither is a
////   free-form key.
////
//// What this does *not* claim: `broker.CallSpec` is an ordinary public
//// record with `op_id`, `step_id` and `budget` fields, shared with
//// `tools` and `client`, so an injected router or launcher could still
//// hand-write a clearance under coordinates of its own invention. Nothing
//// short of making `CallSpec` opaque in the broker would stop that, and
//// that record has callers outside this package. What the types here do
//// close is the case that actually happened: a *configuration* carrying
//// its own copy of the identity fields, filled in by a caller who had no
//// way to see that a sibling configuration had already been filled in
//// differently.
////
//// # Two identities, and why only one of them is here
////
//// `{op_id, step_id}` is the **batch** identity the broker pools on;
//// `{op_id, step_id, source_index}` is the **execution** identity.
//// `code_mode` is `tool.Exclusive`, which forbids a concurrent start and
//// nothing more, so one batch may hold two `code_mode` calls that run
//// back to back sharing a pair. Everything that names a *path* therefore
//// keys on the triple — `client/codemode.exec_root` digests it, and the
//// cap socket and the token file derive from that root — while the ledger
//// keys on the pair, deliberately (`docs/adr/005-budget-pooling-
//// granularity.md`, "Two programs in one batch").
////
//// The source index is deliberately **not** a fourth field here, and the
//// reason is the whole point of this module. What an `ExecIdentity`
//// exports feeds exactly two things: ledger keys and `broker.CallSpec`s.
//// ADR-005 requires a per-call coordinate to exist "without becoming a
//// second axis of the budget key", and `ledger_keys` is one field-read
//// away from whatever this value carries — so a source index stored here
//// would sit beside the trigger, waiting for the next refactor to
//// "complete" the key with the obviously-available third field and mint
//// one ledger per call in a batch. That is an amplification the model
//// controls, because the model authors the batch. A coordinate that
//// names paths belongs where the paths are named.
////
//// # The widening, and why it lives here
////
//// An approved escalation widens a code-mode execution by handing it
//// grants, and grants are the only way `broker/policy.compose` ever
//// widens anything. Those grants have exactly the requirements the
//// identity has — one threaded value, derived per phase, with no way for
//// a caller to assemble a second — so they ride the same value rather
//// than a fourth field on four configuration records. `widened_by` is
//// the only way to attach them, `grants` the only way to read them back,
//// and both `PhaseIdentity` and `ExecIdentity` stay opaque.
////
//// The derivation is where the interesting decision is: **`run_phase`
//// carries the grants and `build_phase` drops them.** An approval widens
//// the program's own execution, never the hermetic build that produced
//// it. Three reasons, in the order they matter:
////
//// 1. Composition applies grants *after* the meet, so a
////    `GrantNetwork(NetworkFull)` reaching the build call would put the
////    network back on inside a build whose entire security property is
////    that it is pinned and offline. The build states
////    `network: NetworkOff` as a requirement and `RefuseNarrowed` as its
////    response precisely so that it cannot run any other way, and a
////    grant is the one thing in the system that can overrule a
////    requirement.
//// 2. Nothing a submitted program says changes what the build asks for.
////    Its policy is the pipeline's — one writable root, the toolchain
////    readable, the network off — so a build refused on policy is a
////    session base that cannot host a hermetic build at all. That is an
////    operator's misconfiguration, not a decision a human is being asked
////    to make about *this* program.
//// 3. The two phases are deliberately different propositions: a
////    different jail, a different policy, a different enforcement
////    report. Widening the build is not the same act as widening the
////    program, and a mechanism that could not tell them apart would be
////    consent to one spent on the other.
////
//// Because `build_phase` is the only way to obtain a build phase, this
//// is a property of the types rather than of the four clearance sites
//// remembering to pass `[]`: every one of them now reads
//// `identity.grants(phase)`, and for a build phase that is empty by
//// construction.

import broker/budget.{type Budget}
import broker/policy.{type Grant}
import core/ids.{type OpId}
import gleam/list

/// The sub-step the build phase runs under when it is accounted
/// separately: `step_id <> build_suffix`.
///
/// Public because the end-to-end asserts on the derived step, and because
/// a reader tracing a `-build` ledger in a broker log deserves to find the
/// one place it comes from.
pub const build_suffix = "-build"

/// Which stage of one execution a `PhaseIdentity` belongs to.
///
/// The two phases are jailed separately and report their enforcement
/// separately, so they are named rather than left implicit in which
/// configuration record happened to be holding the identity.
pub type Phase {
  /// The hermetic `gleam build` (`codemode/build`).
  Build

  /// The satellite node and every capability call the program makes
  /// (`codemode/satellite`).
  Run
}

/// How the build phase's clearances are accounted against the broker's
/// pooled ledger.
///
/// This is the whole of the choice an execution has about its ledger
/// count, which is why it is two variants and not a step id: there is no
/// way to spell a third ledger.
pub type BuildLedger {
  /// The build clears under the execution's own `{op_id, step_id}`, so the
  /// build, the node and every capability call share one pooled ledger and
  /// one wall deadline. This is what production wants: the whole execution
  /// is one batch, and `max_outstanding` bounds all of it together.
  BuildSharesLedger

  /// The build clears under the derived sub-step `step_id <> "-build"`, so
  /// it gets a ledger of its own. Legitimate where the build is a
  /// separately accounted phase — it is a different jail under a different
  /// policy, and it has finished before the node starts, so the two caps
  /// are never live at once. The end-to-end uses this.
  BuildHasOwnLedger
}

/// The identity one whole code-mode execution runs under: the operation
/// and step the broker keys its pooled ledger by, the one parent budget
/// every phase draws on, and where the build phase is accounted.
///
/// Opaque: `for_execution` mints one, `build_phase` and `run_phase` derive
/// from it, and nothing else can produce one. See the module doc for what
/// that buys.
pub opaque type ExecIdentity {
  ExecIdentity(
    op_id: OpId,
    step_id: String,
    budget: Budget,
    build_ledger: BuildLedger,
    grants: List(Grant),
  )
}

/// One phase of one execution, ready to be turned into clearances: the
/// `{op_id, step_id}` the broker keys on, the budget the ledger is opened
/// with, and which phase this is.
///
/// Opaque, and obtainable only from an `ExecIdentity`. That is the type-
/// level half of the invariant: a build configuration cannot carry an
/// identity of its own, because it cannot construct one.
pub opaque type PhaseIdentity {
  PhaseIdentity(
    phase: Phase,
    op_id: OpId,
    step_id: String,
    budget: Budget,
    grants: List(Grant),
  )
}

/// Mints the identity for one execution. The build phase shares the
/// execution's ledger unless `with_own_build_ledger` says otherwise.
///
/// ## Examples
///
/// ```gleam
/// // identity.for_execution(op, step_id: "turn-4", budget:)
/// //   |> identity.ledger_keys
/// //   |> list.length == 1
/// ```
///
pub fn for_execution(
  op_id op_id: OpId,
  step_id step_id: String,
  budget budget: Budget,
) -> ExecIdentity {
  ExecIdentity(
    op_id:,
    step_id:,
    budget:,
    build_ledger: BuildSharesLedger,
    grants: [],
  )
}

/// Accounts the build phase against its own ledger, under the derived
/// sub-step `step_id <> "-build"`.
///
/// ## Examples
///
/// ```gleam
/// // identity.for_execution(op, step_id: "turn-4", budget:)
/// //   |> identity.with_own_build_ledger
/// //   |> identity.build_phase
/// //   |> identity.step_id == "turn-4-build"
/// ```
///
pub fn with_own_build_ledger(identity: ExecIdentity) -> ExecIdentity {
  ExecIdentity(..identity, build_ledger: BuildHasOwnLedger)
}

/// The same execution under a tighter budget.
///
/// The operation and step are untouched, so this cannot add a ledger —
/// `ledger_keys` returns the same keys before and after. What it changes is
/// the wall deadline a phase enforces on itself and the budget a ledger
/// that does not exist yet would be opened with; a ledger the execution
/// has already opened keeps the budget it was opened with, which is the
/// broker's rule and not this module's.
///
/// ## Examples
///
/// ```gleam
/// // identity.ledger_keys(identity.under_budget(id, short))
/// //   == identity.ledger_keys(id)
/// ```
///
pub fn under_budget(
  identity: ExecIdentity,
  budget budget: Budget,
) -> ExecIdentity {
  ExecIdentity(..identity, budget:)
}

/// The same execution, widened by an approved escalation's grants.
///
/// This is the only way grants enter the pipeline, and it is deliberately
/// a setter on the one threaded value rather than a field on
/// `ExecConfig`, `BuildConfig`, `SatelliteConfig` and `LaunchConfig`: four
/// places to write a widening is four places for a caller to write a
/// *different* widening, which is the defect the identity threading closed
/// for operations and steps.
///
/// The grants are the ones a human approved for this execution's action
/// and nothing else. A grant that cannot be attributed to one execution
/// must widen nothing, so a caller with no approval in hand calls this
/// with `[]` or does not call it at all — there is no session-wide list to
/// fall back on, here or anywhere below.
///
/// Replaces rather than accumulates: two approvals for one execution are
/// one set of grants, assembled by whoever holds them, not something this
/// value quietly unions on repeated calls.
///
/// ## Examples
///
/// ```gleam
/// // identity.for_execution(op, step_id: "turn-4", budget:)
/// //   |> identity.widened_by([policy.GrantEnv(name: "CC")])
/// //   |> identity.run_phase
/// //   |> identity.grants == [policy.GrantEnv(name: "CC")]
/// ```
///
pub fn widened_by(
  identity: ExecIdentity,
  grants grants: List(Grant),
) -> ExecIdentity {
  ExecIdentity(..identity, grants:)
}

/// The build phase, derived from the execution's identity: the same
/// operation, the same budget, the step the execution's `BuildLedger`
/// says the build is accounted under — and **no grants**, whatever the
/// execution carries. The module doc argues why the hermetic build is the
/// one stage an approval never widens.
///
/// ## Examples
///
/// ```gleam
/// // identity.phase(identity.build_phase(id)) == identity.Build
/// ```
///
pub fn build_phase(identity: ExecIdentity) -> PhaseIdentity {
  PhaseIdentity(
    phase: Build,
    op_id: identity.op_id,
    step_id: build_step(identity),
    budget: identity.budget,
    // Dropped, not forwarded: an approval widens the program's own
    // execution and never the hermetic build that produced it. The module
    // doc argues the three reasons; this line is where the argument is
    // enforced, and it is the only place in the pipeline that decides it.
    grants: [],
  )
}

/// The run phase, derived from the execution's identity: the execution's
/// own `{op_id, step_id}`, budget and approved grants, unchanged. The node
/// and every capability call the program makes clear under this, so this
/// is the one phase an approved escalation widens.
///
/// ## Examples
///
/// ```gleam
/// // identity.phase(identity.run_phase(id)) == identity.Run
/// ```
///
pub fn run_phase(identity: ExecIdentity) -> PhaseIdentity {
  PhaseIdentity(
    phase: Run,
    op_id: identity.op_id,
    step_id: identity.step_id,
    budget: identity.budget,
    grants: identity.grants,
  )
}

/// Which phase this identity belongs to.
///
/// ## Examples
///
/// ```gleam
/// // identity.phase(identity.run_phase(id)) == identity.Run
/// ```
///
pub fn phase(identity: PhaseIdentity) -> Phase {
  identity.phase
}

/// The operation this phase clears under. Every phase of one execution
/// answers the same operation, which is what makes `broker.abort` reach
/// all of them.
///
/// ## Examples
///
/// ```gleam
/// // identity.op_id(identity.build_phase(id)) == identity.op_id(identity.run_phase(id))
/// ```
///
pub fn op_id(identity: PhaseIdentity) -> OpId {
  identity.op_id
}

/// The step this phase clears under: the execution's own, or the derived
/// `-build` sub-step.
///
/// ## Examples
///
/// ```gleam
/// // identity.step_id(identity.run_phase(id)) == "turn-4"
/// ```
///
pub fn step_id(identity: PhaseIdentity) -> String {
  identity.step_id
}

/// The pooled budget this phase draws on — the execution's one parent
/// budget, never a per-phase copy.
///
/// ## Examples
///
/// ```gleam
/// // identity.pooled_budget(identity.build_phase(id))
/// //   == identity.pooled_budget(identity.run_phase(id))
/// ```
///
pub fn pooled_budget(identity: PhaseIdentity) -> Budget {
  identity.budget
}

/// The approved grants this phase's clearances compose with — the run
/// phase's, and empty for a build phase whatever the execution carries.
///
/// Every clearance the pipeline builds reads its grants from here rather
/// than writing a list of its own, so "which phases an approval widens"
/// is answered once, in `build_phase` and `run_phase`, instead of at four
/// call sites that could drift apart.
///
/// ## Examples
///
/// ```gleam
/// // identity.grants(identity.build_phase(widened)) == []
/// ```
///
pub fn grants(identity: PhaseIdentity) -> List(Grant) {
  identity.grants
}

/// The pair the broker keys its pooled ledger by, for this phase.
///
/// ## Examples
///
/// ```gleam
/// // identity.ledger_key(identity.run_phase(id)) == #(op, "turn-4")
/// ```
///
pub fn ledger_key(identity: PhaseIdentity) -> #(OpId, String) {
  #(identity.op_id, identity.step_id)
}

/// Every distinct ledger this execution can open, in the order the
/// pipeline reaches them.
///
/// This is the property the refactor exists to make readable: the ledger
/// count is a function of the identity value alone, computable before
/// anything runs, and it is one or two. A caller cannot widen it, because
/// there is no third phase to derive and no configuration record left that
/// carries coordinates of its own.
///
/// ## Examples
///
/// ```gleam
/// // list.length(identity.ledger_keys(id)) == 1
/// // list.length(identity.ledger_keys(identity.with_own_build_ledger(id))) == 2
/// ```
///
pub fn ledger_keys(identity: ExecIdentity) -> List(#(OpId, String)) {
  [build_phase(identity), run_phase(identity)]
  |> list.map(ledger_key)
  |> list.unique
}

// The build's step is the execution's own or its `-build` sub-step; there
// is no third answer, which is the point of `BuildLedger` being an ADT
// rather than a step id the caller writes.
fn build_step(identity: ExecIdentity) -> String {
  case identity.build_ledger {
    BuildSharesLedger -> identity.step_id
    BuildHasOwnLedger -> identity.step_id <> build_suffix
  }
}
