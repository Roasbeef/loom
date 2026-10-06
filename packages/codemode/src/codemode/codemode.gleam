//// The code-mode orchestrator: vet, then compile, then run — the whole
//// pipeline of `docs/architecture/code-mode.md`, driven end to end.
////
//// `execute` threads a model-written program through the three trust
//// stages in order, short-circuiting at the first that refuses:
////
//// 1. **Vet** (`codemode/vet`) — the pure import/`@external` lint. A
////    rejection returns in-band as `VetRejected`: no compile, no
////    satellite, the model reads the structured rejections and fixes the
////    program.
//// 2. **Compile** (`codemode/compile`) — the hermetic build against the
////    pinned prelude. A build/type error returns in-band as
////    `CompileFailed`; the type checker doubles as the tool-argument
////    validator, so a mistyped capability call is caught here, cheaply,
////    before any satellite spins up.
//// 3. **Run** (`codemode/satellite`) — the jailed satellite that services
////    the program's capability calls. Its structured `Outcome`, or a
////    `RunError`, comes back in `Ran` / `RunFailed`.
////
//// Every stage's failure is a value, not a crash: `execute` is total.
////
//// # One rewrite, for unused imports only
////
//// A build that fails with nothing but unused-import warnings is run once
//// more without those imports (`codemode/unused_imports`): the rewritten
//// source is vetted again, built, content-addressed and returned as the
//// program (`Ran.source`), and `Execution.edits` says what was removed.
//// Any other diagnostic leaves the failure exactly as the compiler said
//// it, and there is never a second rewrite.
////
//// # The durable-entry seam
////
//// A code-mode program's source and its artifact are stored as entries, so
//// every execution is auditable history and a promotion candidate (design
//// §7, the promotion ladder). `execute` does not reach into storage
//// itself — it *returns* the source and the artifact (whose
//// `manifest_hash` is the durable fingerprint) in the `Ran` outcome, and
//// the runtime persists them. Keeping persistence at the caller preserves
//// the purity layering: this module orchestrates, the runtime commits.

import broker/broker.{type Broker}
import broker/policy.{type Grant} as _
import codemode/compile.{type Artifact, type CompileError, type CompileService}
import codemode/enforcement.{
  type Enforcement, type Report, type Widening, Enforcement, Unreported,
}
import codemode/identity.{type ExecIdentity}
import codemode/run_channel.{type Launcher}
import codemode/satellite.{type Outcome, type RunConfig, type RunError}
import codemode/unused_imports
import codemode/vet.{type Rejection, type Vetted}
import codemode/vet/policy.{type VetPolicy}
import gleam/list
import gleam/result
import tools/call_record.{type CallLog}

/// One whole code-mode execution: how far it got, what the kernel
/// enforced on each jailed stage, and what an approved escalation
/// widened.
///
/// All three are always present. A caller cannot read an outcome without
/// also reading what confined the stages that produced it, and a stage
/// that made no report says why (`codemode/enforcement`) — which is never
/// a claim it was confined. `widening` is the same discipline applied to
/// the other direction: an execution that ran under grants a human
/// approved says so, naming them, and one that did not says which of the
/// two ways that happened. A widening that could not be found in the
/// record would be a widening nobody reviews.
///
/// `calls` is what the program did: the host's record of its capability
/// calls (protocol change 060). It is empty for an execution that never
/// reached a node, and it is present for a run that failed, because a
/// deadline or a dead satellite is exactly when the calls made so far
/// matter.
pub type Execution {
  Execution(
    outcome: ExecOutcome,
    enforcement: Enforcement,
    widening: Widening,
    calls: CallLog,
    /// What the harness changed in the submitted program before it ran, one
    /// line per change (`removed unused import gleam/int (line 3)`), in
    /// source order. Empty unless the build named unused imports and the
    /// program was rebuilt without them (`unused_imports`); when it is not
    /// empty, `Ran.source` is the rewritten program, the one that was
    /// vetted, built and run, and diagnostics refer to its line numbers.
    edits: List(String),
    /// Original Launch resource custody, independent of program outcome.
    custody: satellite.RunCustody,
  )
}

/// The result of running a code-mode program end to end. Each variant is
/// the in-band outcome of the stage that settled it.
pub type ExecOutcome {
  /// Vetting rejected the program; every violation is listed so the model
  /// can fix them in one pass.
  VetRejected(rejections: List(Rejection))

  /// The program vetted but did not compile — a build or type error.
  CompileFailed(error: CompileError)

  /// The program compiled but the satellite could not run it to an
  /// outcome.
  RunFailed(error: RunError)

  /// The program ran and returned a structured outcome. `source` and
  /// `artifact` are handed back for the runtime to persist as a durable
  /// entry (the durable-entry seam; see the module doc).
  Ran(source: String, artifact: Artifact, outcome: Outcome)
}

/// The injected dependencies `execute` needs beyond the source and its vet
/// policy: the whole compile service, the running owner broker, the satellite
/// configuration and launcher, and the one execution identity.
///
/// `identity` is the only place in the whole pipeline an operation, a
/// step, a budget or an approval's grants can be written. The compile,
/// satellite and launch configurations carry none, and `execute` derives
/// the build and run phases from this one value — so how many pooled
/// ledgers the execution opens is `identity.ledger_keys(config.identity)`,
/// readable before anything runs and never widened by a caller
/// (`codemode/identity`, `docs/adr/005-budget-pooling-granularity.md`).
///
/// The grants an approved escalation attributed to this execution ride
/// the same value, through `identity.widened_by`. That is what makes an
/// approval spendable here at all, and it is one field rather than four
/// for the reason the identity is: a widening a caller could write in two
/// places is a widening a caller could write two ways. There is no
/// session-wide grant list to fall back on — an approval that cannot be
/// attributed to this execution widens nothing (design §5.3).
pub type ExecConfig {
  ExecConfig(
    /// The owner-selected import and foreign-interface policy.
    vet_policy: VetPolicy,
    /// Whole physical preparation/build service; invoked only after vetting
    /// and generated-import selection, with the derived build phase.
    compile: CompileService,
    /// Owner authority for the satellite capability router and pooled budget.
    broker: Broker,
    /// The one execution identity from which build and run phases derive.
    identity: ExecIdentity,
    /// Owner token checks, router and capability admission dependencies.
    satellite: RunConfig,
    /// Physical satellite launcher, returning local channel/teardown handles.
    launch: Launcher,
  )
}

/// Runs one model-written program through vet → compile → run, returning
/// one structured `Execution`. Total: every failure is a value, and every
/// outcome carries both stages' enforcement reports and the widening.
///
/// ## Examples
///
/// ```gleam
/// let execution = codemode.execute(source, configuration)
/// // execution.enforcement carries both physical stages' reports.
/// ```
pub fn execute(source: String, config: ExecConfig) -> Execution {
  case vet.vet(source, config.vet_policy) {
    vet.Rejected(rejections) -> vet_rejected(rejections, config)
    vet.Passed(vetted) -> compile_and_run(source, vetted, config)
  }
}

// The grants this execution would spend if it got as far as running: the
// run phase's, read off the one identity, which is also what every
// clearance the run phase makes reads. Deriving the reported set from the
// same accessor the composing sites use is deliberate — a report assembled
// from `config` directly could say "widened" about grants the build phase
// had already dropped.
fn approved(config: ExecConfig) -> List(Grant) {
  identity.grants(identity.run_phase(config.identity))
}

// Nothing was dispatched, so nothing about a jail is claimed — and the two
// stages say that in as many words rather than by omission. An approval
// attributed to this execution went unspent, and says so: a human answered
// a question and the program never reached the door it opened.
fn vet_rejected(rejections: List(Rejection), config: ExecConfig) -> Execution {
  Execution(
    outcome: VetRejected(rejections),
    enforcement: Enforcement(
      build: Unreported(
        "vetting refused the program, so no build was dispatched",
      ),
      node: Unreported("vetting refused the program, so no node was launched"),
    ),
    widening: enforcement.unspent(
      carrying: approved(config),
      because: "vetting refused the program, so no stage composed the grants",
    ),
    calls: call_record.empty(),
    edits: [],
    custody: satellite.NoLaunchResources,
  )
}

fn compile_and_run(
  source: String,
  vetted: Vetted,
  config: ExecConfig,
) -> Execution {
  let first = compile_once(vetted, compile.Original, config)

  // One rewrite at most. The second build's result is final whatever it
  // says: a program whose unused imports were not the whole problem gets the
  // second build's diagnostics, and nothing is rewritten twice.
  let #(source, compiled, edits) = case rewritten(vetted, first, config) {
    Ok(#(next, rewrite)) -> #(
      rewrite.source,
      compile_once(next, compile.UnusedImportRewrite, config),
      rewrite.notes,
    )
    Error(Nil) -> #(source, first, [])
  }
  case compiled.result {
    Error(error) -> compile_failed(compiled.enforcement, error, edits, config)
    Ok(artifact) ->
      run_and_report(source, artifact, compiled.enforcement, edits, config)
  }
}

// The build's identity is *derived* here, from the execution's, rather
// than supplied alongside it: that derivation is the only thing standing
// between the build and a ledger of its own invention.
fn compile_once(
  vetted: Vetted,
  attempt: compile.CompileAttempt,
  config: ExecConfig,
) -> compile.Compiled {
  config.compile.compile(compile.CompileRequest(
    attempt:,
    vetted:,
    dependencies: config.compile.dependencies,
    generated: imported(config.compile.generated, vetted),
    identity: identity.build_phase(config.identity),
  ))
}

// The program without the imports a failed build named as unused, vetted
// again, when that is the whole of the failure.
//
// What runs is what was vetted, so the rewritten source goes back through
// `vet.vet` under the same policy and the new `Vetted` is what is built. A
// removal can only narrow what a program imports, so the vet is not
// expected to refuse; if it ever does, the original failure stands rather
// than a program nobody vetted being built.
fn rewritten(
  vetted: Vetted,
  compiled: compile.Compiled,
  config: ExecConfig,
) -> Result(#(Vetted, unused_imports.Rewrite), Nil) {
  case compiled.result {
    Error(compile.BuildRejected(diagnostics:)) -> {
      use rewrite <- result.try(unused_imports.rewrite(
        vet.vetted_source(vetted),
        diagnostics,
        "src/" <> compile.program_module <> ".gleam",
      ))
      case vet.vet(rewrite.source, config.vet_policy) {
        vet.Passed(next) -> Ok(#(next, rewrite))
        vet.Rejected(_) -> Error(Nil)
      }
    }
    Error(compile.WorkspaceSetupFailed(reason: _))
    | Error(compile.BuildUnavailable(reason: _))
    | Error(compile.ArtifactIncomplete(reason: _))
    | Ok(_) -> Error(Nil)
  }
}

// The generated capability modules this program actually imports.
//
// A host may have generated a module per configured MCP server, and a
// build that vendored all of them would cost every program the whole
// configuration: the compiler would type-check a façade per tool of
// every server, whether or not the program named one. So the table is
// narrowed here, where the `Vetted` is — the parsed module, not the
// source, so the set is the compiler's own reading of the import list —
// and the cost of a configured server scales with the imports a program
// wrote rather than with what an operator enabled.
//
// It is a *cost* filter and not an authorization one, and the difference
// matters: what a program may import is the vetting allowlist's
// decision, already made by the time this runs, and a module written
// into a build the program does not import is dead source. Narrowing
// cannot widen anything.
fn imported(
  generated: List(#(String, String)),
  vetted: Vetted,
) -> List(#(String, String)) {
  let imports =
    list.map(vet.vetted_module(vetted).imports, fn(definition) {
      definition.definition.module
    })
  list.filter(generated, fn(module) { list.contains(imports, module.0) })
}

fn compile_failed(
  build: Report,
  error: CompileError,
  edits: List(String),
  config: ExecConfig,
) -> Execution {
  Execution(
    outcome: CompileFailed(error),
    enforcement: Enforcement(
      build:,
      node: Unreported("the program did not compile, so no node was launched"),
    ),
    // The build ran and the build is never widened, so a failed build
    // spends nothing however much was approved.
    widening: enforcement.unspent(
      carrying: approved(config),
      because: "the program did not compile, and the hermetic build is never "
        <> "widened by an approval",
    ),
    calls: call_record.empty(),
    edits:,
    custody: satellite.NoLaunchResources,
  )
}

fn run_and_report(
  source: String,
  artifact: Artifact,
  build: Report,
  edits: List(String),
  config: ExecConfig,
) -> Execution {
  let ran =
    satellite.run(
      artifact,
      identity.run_phase(config.identity),
      config.broker,
      config.satellite,
      config.launch,
    )
  Execution(
    outcome: case ran.outcome {
      Error(error) -> RunFailed(error)
      Ok(outcome) -> Ran(source:, artifact:, outcome:)
    },
    enforcement: Enforcement(build:, node: ran.node),
    widening: run_widening(approved(config), ran.outcome),
    calls: ran.calls,
    edits:,
    custody: ran.custody,
  )
}

// Whether the run phase actually got far enough to compose its grants.
//
// Token minting and host startup can fail before whole Launch sees the grants.
// The persistent-host token-file variant remains in the shared error type, but
// foreground placement now belongs to its physical Launch adapter. A lost Launch
// reply cannot establish that the grants were never offered to a policy. Every other ending, refusal included, went
// through `launch`, which composes `base ⊕ requirements ⊕ grants` before
// it does anything else; a launch *refused* under grants is still a
// clearance that composed them, and saying otherwise would hide the case
// an operator most wants to see: an approval that was spent and still was
// not enough.
//
// Matched variant by variant rather than with a catch-all, so a ninth
// `RunError` cannot silently inherit either answer.
fn run_widening(
  grants: List(Grant),
  outcome: Result(Outcome, RunError),
) -> Widening {
  case outcome {
    Error(satellite.TokenMintFailed(reason: _))
    | Error(satellite.TokenFileFailed(reason: _))
    | Error(satellite.HostUnavailable(reason: _)) ->
      enforcement.unspent(
        carrying: grants,
        because: "the satellite host never started, so no clearance composed "
          <> "the grants",
      )
    Error(satellite.LaunchRejected(reason: _))
    | Error(satellite.LaunchOutcomeUnknown(reason: _))
    | Error(satellite.DeadlineExceeded)
    | Error(satellite.SatelliteGone(reason: _))
    | Error(satellite.ChannelFaulted(reason: _))
    | Error(satellite.OutcomeMalformed(reason: _))
    | Ok(_outcome) -> enforcement.widened(by: grants)
  }
}
