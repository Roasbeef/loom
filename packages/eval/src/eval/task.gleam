//// A task is the unit the instrument measures: one prompt, one starting
//// workspace and one hidden verifier, addressed by the digest of its own
//// canonical bytes.
////
//// Three producers mint tasks — a person writing a small fixture, the miner
//// turning a fix commit from Loom's own history into a regression task, and
//// an importer reading a Harbor dataset — and the runner never branches on
//// which one did. Provenance is recorded and hashed, but nothing trusts it:
//// what the runner acts on is the workspace and the verifier.
////
//// Identity is the rule that keeps a benchmark honest. A task's `id` is the
//// SHA-256 of its canonical encoding with the `id` field blank, so editing
//// any byte of the prompt, workspace or verifier mints a different task.
//// "Fixing" a task to make an agent pass is therefore not an edit but a new
//// task, and the old one stays in every ledger that measured it.
////
//// The verifier is hidden by construction rather than by convention. Its
//// files live here, outside the workspace, and the runner writes them into
//// a copy of the frozen workspace only after the agent's session has been
//// retired, then runs the verifier in a fresh jail
//// (`docs/design-notes/eval-instrument.md` §3).

/// One versioned, content-addressed evaluation task.
pub type Task {
  Task(
    /// SHA-256 hex of the canonical encoding with this field blank. Any
    /// change to any other field is a different task.
    id: String,
    /// A human handle for reports. Informational only: rows are paired by
    /// `id`, never by name.
    name: String,
    /// What the agent is told, at most 8 KiB. For a mined task this is the
    /// commit subject (and body, unless the body names a hidden test).
    prompt: String,
    /// The tree the agent starts from.
    workspace: Workspace,
    /// How the agent's result is graded once the agent is gone.
    verifier: Verifier,
    /// Failure-taxonomy and family tags, used for split quotas and for
    /// per-tag pass rates in reports.
    tags: List(String),
    /// Where the task came from. Hashed into `id`, never trusted.
    provenance: Provenance,
  )
}

/// The starting tree for a trial.
pub type Workspace {
  /// A small fixture carried in the task itself: at most 64 files and
  /// 256 KiB, the bounds `client/evolution/tasks.Fixture` already uses.
  Inline(files: List(#(String, String)))

  /// A tree from a git repository. `tree` is `git rev-parse <commit>^{tree}`,
  /// which is already a content digest of the whole worktree, so the task
  /// needs no second hash of it. `prepare` is the argv run on the host, at a
  /// trusted commit, before the agent starts (for Loom,
  /// `gleam deps download` and a warm build), and its time is the trial's
  /// cold start.
  GitTree(
    repository: String,
    commit: String,
    tree: String,
    prepare: List(List(String)),
  )
}

/// How a finished trial is graded.
pub type Verifier {
  /// Exact expected file contents: the version-one scorer
  /// (`client/evolution/fixture.score`), kept so hand-written fixtures and
  /// the governed task sets they came from stay expressible.
  ExpectedFiles(expected: List(#(String, String)))

  /// A program run in a fresh jail over a copy of the agent's frozen
  /// workspace, after `files` have been written into that copy.
  Program(
    /// Hidden files staged into the copy: for a mined task, the commit's
    /// own test changes.
    files: List(#(String, String)),
    /// The command, run with the copy as its working directory.
    argv: List(String),
    /// Test ids that failed before the fix and passed after it. Every one
    /// must pass for full reward.
    fail_to_pass: List(String),
    /// Test ids that passed both before and after the fix. A regression in
    /// any of them costs reward.
    pass_to_pass: List(String),
    /// Wall-clock ceiling for the verifier run. Exceeding it is a failed
    /// grade, never an exclusion.
    timeout_ms: Int,
    /// How the rewards in `/logs/verifier/reward.json` (Harbor's contract)
    /// reduce to a pass.
    scoring: Scoring,
  )
}

/// The reduction from a verifier's reward map to a pass, after Harbor and
/// nanocodex's two policies.
pub type Scoring {
  /// Every reported reward must equal 1.0.
  AllRewardsOne

  /// Every reported reward must be strictly positive.
  AllRewardsPositive
}

/// Where a task came from: recorded and hashed, never trusted.
pub type Provenance {
  /// Written by a person.
  HandWritten(author: String)

  /// Mined from a fix commit of a repository's own history.
  MinedCommit(fix: String, parent: String, subject: String)

  /// Imported from a Harbor dataset at a pinned revision.
  HarborImport(dataset: String, revision: String, task: String)
}
