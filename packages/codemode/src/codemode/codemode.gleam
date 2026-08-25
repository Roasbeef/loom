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
import codemode/compile.{type Artifact, type CompileConfig, type CompileError}
import codemode/enforcement.{type Enforcement, Enforcement, Unreported}
import codemode/satellite.{
  type ExecId, type Launcher, type Outcome, type RunError, type SatelliteConfig,
}
import codemode/vet.{type Rejection}
import codemode/vet/policy.{type VetPolicy}

/// One whole code-mode execution: how far it got, and what the kernel
/// enforced on each jailed stage.
///
/// Both are always present. A caller cannot read an outcome without also
/// reading what confined the stages that produced it, and a stage that
/// made no report says why (`codemode/enforcement`) — which is never a
/// claim it was confined.
pub type Execution {
  Execution(outcome: ExecOutcome, enforcement: Enforcement)
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
/// policy: the compile configuration, the running broker, the satellite
/// configuration and launcher, and the pooled execution identity.
pub type ExecConfig {
  ExecConfig(
    vet_policy: VetPolicy,
    compile: CompileConfig,
    broker: Broker,
    exec_id: ExecId,
    satellite: SatelliteConfig,
    launch: Launcher,
  )
}

/// Runs one model-written program through vet → compile → run, returning
/// one structured `Execution`. Total: every failure is a value, and every
/// outcome carries both stages' enforcement reports.
pub fn execute(source: String, config: ExecConfig) -> Execution {
  case vet.vet(source, config.vet_policy) {
    // Nothing was dispatched, so nothing about a jail is claimed — and
    // the two stages say that in as many words rather than by omission.
    vet.Rejected(rejections) ->
      Execution(
        outcome: VetRejected(rejections),
        enforcement: Enforcement(
          build: Unreported(
            "vetting refused the program, so no build was dispatched",
          ),
          node: Unreported(
            "vetting refused the program, so no node was launched",
          ),
        ),
      )
    vet.Passed(vetted) -> {
      let compiled = compile.compile(vetted, config.compile)
      case compiled.result {
        Error(error) ->
          Execution(
            outcome: CompileFailed(error),
            enforcement: Enforcement(
              build: compiled.enforcement,
              node: Unreported(
                "the program did not compile, so no node was launched",
              ),
            ),
          )
        Ok(artifact) -> {
          let ran =
            satellite.run(
              artifact,
              config.exec_id,
              config.broker,
              config.satellite,
              config.launch,
            )
          Execution(
            outcome: case ran.outcome {
              Error(error) -> RunFailed(error)
              Ok(outcome) -> Ran(source:, artifact:, outcome:)
            },
            enforcement: Enforcement(
              build: compiled.enforcement,
              node: ran.node,
            ),
          )
        }
      }
    }
  }
}
