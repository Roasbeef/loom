//// `cap/evolution` — governed self-extension, and the only model-facing route
//// to it. `propose` snapshots a workspace directory into an immutable
//// candidate of one `Kind` (`Extension`, `Program` or `Prompt`).
//// `test_candidate` runs its author tests and `compare` runs a paired prompt
//// comparison; both retain evidence, and `inspect` pages exact bytes.
//// Approval and selection are the operator's (`loom evolution`), never a
//// program's. Once one is selected, `catalogue` lists its exact
//// `candidate_id`, `generation` and input schema, and `invoke` calls it under
//// your authority. `trace` reads bounded transcript excerpts. Results are
//// `report.Value`; a refusal is `EvolutionDenied(code, message)`.
////
//// ## The lifecycle
////
//// `propose` creates no approval or activation, and a request that needs a new
//// trusted capability answers `CoreChangeRequired`. A successful test or
//// comparison approves and selects nothing. A stale `candidate_id` or
//// `generation` is refused rather than rerouted to another version, so
//// keep the exact pair `catalogue` returned. `trace` excludes thinking, and
//// its credential scrubbing is heuristic.
////
//// ## Bounds worth knowing
////
//// A snapshot is bounded to 20 seconds and author tests and program runs to
//// 60. A call that waits more than 120 seconds for the generation owner is
//// refused `Busy`. A paired comparison may only lower the native ceilings in
//// `native_limits`. `catalogue` and
//// `inspect` are paged: pass back `next_offset`, `next_candidate_offset` or
//// `next_offset_bytes` unchanged to continue. A candidate program cannot
//// import this module, so a selected program can never propose, test or
//// invoke another candidate from inside its own run.
////
//// ## Examples
////
//// ```gleam
//// let assert Ok(proposed) =
////   evolution.propose(
////     evolution.Proposal(
////       ..evolution.proposal("skills/tally", "tally", evolution.Program),
////       test_entry: Some("check"),
////     ),
////   )
//// let assert Ok(id) = report.field(proposed, "candidate_id") |> result.try(report.as_string)
//// let assert Ok(_evidence) = evolution.test_candidate(id)
//// ```

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Why an evolution call failed.
pub type EvolutionError {
  /// The catalogue refused the call in band. `code` is
  /// `evolution_refused`; `message` names the refusal, for example
  /// `Bounds`, `Authority`, `Stale` or `CoreChangeRequired`.
  EvolutionDenied(code: String, message: String)

  /// The capability channel could not carry the call.
  EvolutionUnavailable(reason: String)
}

/// What a candidate is.
pub type Kind {
  /// A stateful or stateless tool the operator may promote into the session.
  Extension

  /// A program run through code mode with fresh JSON input on each call.
  Program

  /// A system-prompt profile for the exact model; tested by comparison.
  Prompt
}

/// The source a candidate is captured from.
pub type Proposal {
  Proposal(
    /// A directory inside your workspace, relative to its root.
    directory: String,
    /// The stable candidate name; a new version of one name is a new candidate.
    name: String,
    /// What the candidate is.
    kind: Kind,
    /// The candidate-owned test entry module, when it has one.
    test_entry: Option(String),
    /// Purpose and input contract, shown in the catalogue.
    description: Option(String),
    /// A JSON input schema as text. A program defaults to `{}`.
    input_schema: Option(String),
  )
}

/// A proposal with only the required fields set; extend it with record
/// update syntax.
///
/// ## Examples
///
/// ```gleam
/// evolution.proposal("skills/tally", "tally", evolution.Program)
/// ```
pub fn proposal(directory: String, name: String, kind: Kind) -> Proposal {
  Proposal(
    directory:,
    name:,
    kind:,
    test_entry: None,
    description: None,
    input_schema: None,
  )
}

/// Budget ceilings for a paired prompt comparison. Every field is required
/// and may only lower the matching native ceiling.
pub type Limits {
  Limits(
    /// Paired trial arms, 1 to 20.
    trials: Int,
    /// Aggregate turns, 1 to 20.
    turns: Int,
    /// Aggregate tokens, 1 to 1,000,000.
    tokens: Int,
    /// Aggregate dollars, above zero through 2.
    dollars: Float,
    /// Retained output bytes, 1 to 65,536.
    output_bytes: Int,
    /// Comparison wall milliseconds, 1 to 120,000.
    wall_ms: Int,
  )
}

/// The native ceilings, which a comparison uses when it names no limits.
pub fn native_limits() -> Limits {
  Limits(
    trials: 20,
    turns: 20,
    tokens: 1_000_000,
    dollars: 2.0,
    output_bytes: 65_536,
    wall_ms: 120_000,
  )
}

/// What `inspect` reads.
pub type Target {
  /// The immutable bytes of one candidate.
  CandidateBytes(candidate_id: String)

  /// One retained evidence envelope.
  EvidenceBytes(evidence_id: String)
}

/// Captures a workspace directory as an immutable candidate. The result
/// carries the `candidate_id` that every later call names.
/// Capability: evolution.propose.
///
/// ## Examples
///
/// ```gleam
/// evolution.propose(evolution.proposal("skills/tally", "tally", evolution.Program))
/// ```
pub fn propose(proposal: Proposal) -> Result(Value, EvolutionError) {
  call(
    "evolution.propose",
    list.flatten([
      [
        #("directory", wire.string(proposal.directory)),
        #("name", wire.string(proposal.name)),
        #("kind", wire.string(kind_text(proposal.kind))),
      ],
      text_field("test_entry", proposal.test_entry),
      text_field("description", proposal.description),
      text_field("input_schema", proposal.input_schema),
    ]),
  )
}

// An absent optional field is omitted, never sent as nil, so the host reads
// exactly what the program wrote.
fn text_field(key: String, value: Option(String)) -> List(#(String, Value)) {
  case value {
    None -> []
    Some(text) -> [#(key, wire.string(text))]
  }
}

/// Runs a candidate's author tests in the jail and retains the evidence.
/// For a `Prompt` candidate use `compare`. Success does not approve or
/// select anything. Capability: evolution.test.
///
/// ## Examples
///
/// ```gleam
/// evolution.test_candidate("candidate-id")
/// ```
pub fn test_candidate(candidate_id: String) -> Result(Value, EvolutionError) {
  call("evolution.test", [#("candidate_id", wire.string(candidate_id))])
}

/// Runs a paired coding comparison for a `Prompt` candidate against an
/// independently admitted task set, under `limits`.
/// Capability: evolution.test.
///
/// ## Examples
///
/// ```gleam
/// evolution.compare("candidate-id", "taskset-id", evolution.native_limits())
/// ```
pub fn compare(
  candidate_id: String,
  taskset_id: String,
  limits: Limits,
) -> Result(Value, EvolutionError) {
  call("evolution.test", [
    #("candidate_id", wire.string(candidate_id)),
    #("taskset_id", wire.string(taskset_id)),
    #(
      "limits",
      wire.args([
        #("trials", wire.int(limits.trials)),
        #("turns", wire.int(limits.turns)),
        #("tokens", wire.int(limits.tokens)),
        #("dollars", report.float(limits.dollars)),
        #("output_bytes", wire.int(limits.output_bytes)),
        #("wall_ms", wire.int(limits.wall_ms)),
      ]),
    ),
  ])
}

/// Reads one bounded base64 page of a candidate or of evidence. Start at
/// offset 0 and pass back the returned `next_offset_bytes` to continue.
/// Capability: evolution.inspect.
///
/// ## Examples
///
/// ```gleam
/// evolution.inspect(evolution.CandidateBytes("candidate-id"), 0)
/// ```
pub fn inspect(
  target: Target,
  offset_bytes: Int,
) -> Result(Value, EvolutionError) {
  // Project the target identity into argument fields.
  let subject = case target {
    CandidateBytes(candidate_id:) -> #(
      "candidate_id",
      wire.string(candidate_id),
    )
    EvidenceBytes(evidence_id:) -> #("evidence_id", wire.string(evidence_id))
  }

  call("evolution.inspect", [
    subject,
    #("offset_bytes", wire.int(offset_bytes)),
  ])
}

/// Lists the operator-selected candidates with the exact `candidate_id`,
/// `generation` and input schema `invoke` needs, plus visible candidate
/// metadata. `offset` pages callable entries, `candidate_offset` pages
/// candidates, and `count` bounds the candidates per page.
/// Capability: evolution.catalogue.
///
/// ## Examples
///
/// ```gleam
/// evolution.catalogue(0, 0, 8)
/// ```
pub fn catalogue(
  offset: Int,
  candidate_offset: Int,
  count: Int,
) -> Result(Value, EvolutionError) {
  call("evolution.catalogue", [
    #("offset", wire.int(offset)),
    #("candidate_offset", wire.int(candidate_offset)),
    #("count", wire.int(count)),
  ])
}

/// Calls tool `name` of a discovered candidate with fresh `arguments` under
/// your current authority. Both `candidate_id` and `generation` must match
/// the selection now in force; otherwise the call is refused as stale.
/// Capability: evolution.invoke.
///
/// ## Examples
///
/// ```gleam
/// evolution.invoke("candidate-id", 1, "tally", report.object([#("path", report.string("a.csv"))]))
/// ```
pub fn invoke(
  candidate_id: String,
  generation: Int,
  name: String,
  arguments: Value,
) -> Result(Value, EvolutionError) {
  call("evolution.invoke", [
    #("candidate_id", wire.string(candidate_id)),
    #("generation", wire.int(generation)),
    #("tool", wire.string(name)),
    #("arguments", arguments),
  ])
}

/// Reads up to `limit` (1 to 32) bounded excerpts of this session's own
/// transcript for the actual model, with usage and operator-marked
/// outcomes. Thinking is excluded. Credential scrubbing is heuristic and can
/// miss short unlabelled secrets. Capability: evolution.trace.
///
/// ## Examples
///
/// ```gleam
/// evolution.trace(12)
/// ```
pub fn trace(limit: Int) -> Result(Value, EvolutionError) {
  call("evolution.trace", [#("limit", wire.int(limit))])
}

/// Returns the string representation for a candidate kind.
fn kind_text(kind: Kind) -> String {
  case kind {
    Extension -> "extension"
    Program -> "program"
    Prompt -> "prompt"
  }
}

/// Dispatches a capability call through the internal wire transport.
fn call(
  capability: String,
  fields: List(#(String, Value)),
) -> Result(Value, EvolutionError) {
  dispatch.call(capability, wire.args(fields))
  |> result.map_error(map_error)
}

fn map_error(error: CallError) -> EvolutionError {
  case error {
    Denied(code:, message:) -> EvolutionDenied(code:, message:)
    Unreachable(reason:) -> EvolutionUnavailable(reason:)
  }
}

/// A one-line rendering of an `EvolutionError`.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.error_text(evolution.EvolutionUnavailable("no channel")) == "evolution unavailable: no channel"
/// ```
///
pub fn error_text(error: EvolutionError) -> String {
  case error {
    EvolutionDenied(code:, message:) -> code <> ": " <> message
    EvolutionUnavailable(reason:) -> "evolution unavailable: " <> reason
  }
}
