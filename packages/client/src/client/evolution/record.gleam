//// Immutable evolution records and their canonical content addresses.
//// Candidate hashes include every source, fixture and host-admitted identity.
//// Evidence hashes include the candidate and the complete evaluator observation.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/blob

/// A validated SHA256 candidate identity.
pub opaque type CandidateId {
  CandidateId(String)
}

/// A validated SHA256 observation identity.
pub opaque type EvidenceId {
  EvidenceId(String)
}

/// The execution boundary the candidate requires.
pub type Kind {
  /// A jailed tool or hook.
  Extension

  /// A freshly compiled code-mode skill.
  Program

  /// An exact-model prompt overlay.
  Prompt
}

/// The resolved provider identity, without aliases or family matching.
pub type ModelScope {
  ModelScope(
    /// The resolved provider identifier.
    provider: String,
    /// The exact resolved model identifier.
    model: String,
    /// The wire API variant.
    api: String,
  )
}

/// Where the native host admits this proposal.
pub type Scope {
  /// One live session.
  Session(session_id: String)

  /// Sessions sharing this canonical workspace.
  Workspace(path: String)

  /// An owner-admitted exact model.
  ExactModel(target: ModelScope)
}

/// Host-derived provenance, never authority supplied by the author.
pub type Origin {
  Origin(
    /// The native originating session identity.
    session_id: String,
    /// The strand that authored the proposal.
    strand: String,
    /// The native canonical workspace.
    workspace: String,
    /// The predecessor proposed for revision, when present.
    parent: Option(CandidateId),
  )
}

/// The build, seam and evaluator versions whose evidence is current.
pub type Identity {
  Identity(
    /// The native build and toolchain fingerprint.
    build: String,
    /// The current seam policy and allowlist fingerprint.
    seam: String,
    /// The host evaluator implementation fingerprint.
    evaluator: String,
  )
}

/// A complete immutable proposal.
pub type Candidate {
  Candidate(
    /// The content address of every field in this envelope.
    id: CandidateId,
    /// The stable operator-visible catalogue name.
    name: String,
    /// The runtime boundary this proposal requires.
    kind: Kind,
    /// The publication scope admitted by the native host.
    scope: Scope,
    /// The host-derived author provenance.
    origin: Origin,
    /// The exact build and evaluator identities for this proposal.
    identity: Identity,
    /// Every retained source, test and fixture, as relative path and UTF8 bytes.
    files: List(#(String, String)),
    /// The module or skill function returning the author test outcome.
    test_entry: Option(String),
    /// The model-visible description bound to this version.
    description: String,
    /// The declared fresh JSON input contract.
    input_schema: String,
  )
}

/// The observed result, including interrupted trials.
pub type Verdict {
  /// The evaluator's required checks passed.
  Passed

  /// A required check failed.
  Failed

  /// The evaluator did not obtain a complete result.
  Inconclusive(reason: String)
}

/// Author-owned checks remain distinguishable from independent trials.
pub type Purpose {
  /// The candidate's own jailed test entry.
  AuthorTests

  /// A host-scored comparison against a baseline.
  IndependentRollout
}

/// A bounded host-written observation with a content address.
pub type Evidence {
  Evidence(
    /// The content address of this complete observation.
    id: EvidenceId,
    /// The exact immutable candidate that was evaluated.
    candidate_id: CandidateId,
    /// The host identities under which evaluation occurred.
    identity: Identity,
    /// The host observation time in Unix milliseconds.
    at_ms: Int,
    /// Whether the author or an independent evaluator owns the criteria.
    purpose: Purpose,
    /// The complete, failed or incomplete trial result.
    verdict: Verdict,
    /// The bounded canonical JSON observation written by the host.
    observation: String,
  )
}

/// The selected immutable version and its monotonic publication generation.
pub type Selection {
  Selection(
    /// The immutable candidate used for subsequent invocations.
    candidate_id: CandidateId,
    /// The exact currently approved observation.
    evidence_id: EvidenceId,
    /// The admitted publication boundary.
    scope: Scope,
    /// The name whose current selection this record represents.
    name: String,
    /// The monotonic generation, including rollback transitions.
    generation: Int,
  )
}

/// Validates a candidate digest.
///
/// ## Examples
///
/// `candidate_id(text)` refuses non-SHA256 names.
pub fn candidate_id(text: String) -> Result(CandidateId, String) {
  use Nil <- result.try(valid_digest(text))
  Ok(CandidateId(text))
}

/// Validates an evidence digest.
///
/// ## Examples
///
/// `evidence_id(text)` refuses non-SHA256 names.
pub fn evidence_id(text: String) -> Result(EvidenceId, String) {
  use Nil <- result.try(valid_digest(text))
  Ok(EvidenceId(text))
}

/// Returns the canonical candidate digest.
///
/// ## Examples
///
/// `id_string(id)` is safe to use as a catalogue key.
pub fn id_string(id: CandidateId) -> String {
  let CandidateId(text) = id
  text
}

/// Returns the canonical evidence digest.
///
/// ## Examples
///
/// `evidence_string(id)` is safe to use as a catalogue key.
pub fn evidence_string(id: EvidenceId) -> String {
  let EvidenceId(text) = id
  text
}

/// Assigns the canonical identity to admitted candidate fields.
///
/// ## Examples
///
/// `identified(candidate)` changes its id when source bytes change.
pub fn identified(candidate: Candidate) -> Candidate {
  Candidate(
    ..candidate,
    id: CandidateId(digest(json.to_string(candidate_body(candidate)))),
  )
}

/// Assigns the canonical identity to a host observation.
///
/// ## Examples
///
/// `observed(evidence)` binds the entire observation.
pub fn observed(evidence: Evidence) -> Evidence {
  Evidence(
    ..evidence,
    id: EvidenceId(digest(json.to_string(evidence_body(evidence)))),
  )
}

/// An initial digest used only before computing a record's content address.
///
/// ## Examples
///
/// `placeholder()` never authorizes execution.
pub fn placeholder() -> CandidateId {
  CandidateId(string.repeat("0", 64))
}

/// An initial evidence digest used before computing its content address.
///
/// ## Examples
///
/// `evidence_placeholder()` is replaced by `observed`.
pub fn evidence_placeholder() -> EvidenceId {
  EvidenceId(string.repeat("0", 64))
}

/// Encodes a candidate with deterministic field and file ordering.
///
/// ## Examples
///
/// `encode_candidate(candidate)` is the persisted envelope.
pub fn encode_candidate(candidate: Candidate) -> String {
  json.to_string(
    json.object([
      #("id", json.string(id_string(candidate.id))),
      #("candidate", candidate_body(candidate)),
    ]),
  )
}

/// Decodes and rechecks a persisted content address.
///
/// ## Examples
///
/// `decode_candidate(encode_candidate(candidate))` verifies its bytes.
pub fn decode_candidate(text: String) -> Result(Candidate, String) {
  use candidate <- result.try(
    json.parse(text, candidate_decoder())
    |> result.replace_error("invalid candidate envelope"),
  )
  case identified(candidate).id == candidate.id {
    True -> Ok(candidate)
    False -> Error("candidate content address changed")
  }
}

/// Encodes a durable evidence envelope.
///
/// ## Examples
///
/// `encode_evidence(evidence)` retains the host observation.
pub fn encode_evidence(evidence: Evidence) -> String {
  json.to_string(
    json.object([
      #("id", json.string(evidence_string(evidence.id))),
      #("evidence", evidence_body(evidence)),
    ]),
  )
}

/// Decodes evidence and verifies its content address.
///
/// ## Examples
///
/// `decode_evidence(text)` refuses altered observations.
pub fn decode_evidence(text: String) -> Result(Evidence, String) {
  use evidence <- result.try(
    json.parse(text, evidence_decoder())
    |> result.replace_error("invalid evidence envelope"),
  )
  case observed(evidence).id == evidence.id {
    True -> Ok(evidence)
    False -> Error("evidence content address changed")
  }
}

/// Renders the exact scope as a stable database key.
///
/// ## Examples
///
/// `scope_key(Session("s"))` cannot collide with a workspace scope.
pub fn scope_key(scope: Scope) -> String {
  json.to_string(encode_scope(scope))
}

/// Encodes an exact activation scope.
///
/// ## Examples
///
/// `encode_scope(scope)` preserves exact provider and model identity.
pub fn encode_scope(scope: Scope) -> json.Json {
  case scope {
    Session(id) ->
      json.object([
        #("kind", json.string("session")),
        #("session", json.string(id)),
      ])
    Workspace(path) ->
      json.object([
        #("kind", json.string("workspace")),
        #("workspace", json.string(path)),
      ])
    ExactModel(target) ->
      json.object([
        #("kind", json.string("model")),
        #("provider", json.string(target.provider)),
        #("model", json.string(target.model)),
        #("api", json.string(target.api)),
      ])
  }
}

/// Decodes the admitted scope totally.
///
/// ## Examples
///
/// `scope_decoder()` rejects unknown scope kinds.
pub fn scope_decoder() -> decode.Decoder(Scope) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "session" -> {
      use id <- decode.field("session", decode.string)
      decode.success(Session(id))
    }
    "workspace" -> {
      use path <- decode.field("workspace", decode.string)
      decode.success(Workspace(path))
    }
    "model" -> {
      use provider <- decode.field("provider", decode.string)
      use model <- decode.field("model", decode.string)
      use api <- decode.field("api", decode.string)
      decode.success(ExactModel(ModelScope(provider:, model:, api:)))
    }
    _ -> decode.failure(Session(""), "known scope")
  }
}

fn candidate_body(candidate: Candidate) -> json.Json {
  json.object([
    #("name", json.string(candidate.name)),
    #("kind", json.string(kind_name(candidate.kind))),
    #("scope", encode_scope(candidate.scope)),
    #("origin", encode_origin(candidate.origin)),
    #("identity", encode_identity(candidate.identity)),
    #(
      "files",
      json.array(
        list.sort(candidate.files, fn(a, b) { string.compare(a.0, b.0) }),
        fn(file) {
          json.object([
            #("path", json.string(file.0)),
            #("text", json.string(file.1)),
          ])
        },
      ),
    ),
    #("test_entry", optional_text(candidate.test_entry)),
    #("description", json.string(candidate.description)),
    #("input_schema", json.string(candidate.input_schema)),
  ])
}

fn evidence_body(evidence: Evidence) -> json.Json {
  json.object([
    #("candidate_id", json.string(id_string(evidence.candidate_id))),
    #("identity", encode_identity(evidence.identity)),
    #("at_ms", json.int(evidence.at_ms)),
    #(
      "purpose",
      json.string(case evidence.purpose {
        AuthorTests -> "author_tests"
        IndependentRollout -> "independent_rollout"
      }),
    ),
    #(
      "verdict",
      json.string(case evidence.verdict {
        Passed -> "passed"
        Failed -> "failed"
        Inconclusive(_) -> "inconclusive"
      }),
    ),
    #(
      "reason",
      json.string(case evidence.verdict {
        Inconclusive(reason) -> reason
        Passed | Failed -> ""
      }),
    ),
    #("observation", json.string(evidence.observation)),
  ])
}

fn encode_identity(identity: Identity) -> json.Json {
  json.object([
    #("build", json.string(identity.build)),
    #("seam", json.string(identity.seam)),
    #("evaluator", json.string(identity.evaluator)),
  ])
}

fn encode_origin(origin: Origin) -> json.Json {
  json.object([
    #("session", json.string(origin.session_id)),
    #("strand", json.string(origin.strand)),
    #("workspace", json.string(origin.workspace)),
    #("parent", optional_text(option.map(origin.parent, id_string))),
  ])
}

fn optional_text(value: Option(String)) -> json.Json {
  case value {
    Some(text) -> json.string(text)
    None -> json.null()
  }
}

fn identity_decoder() -> decode.Decoder(Identity) {
  use build <- decode.field("build", decode.string)
  use seam <- decode.field("seam", decode.string)
  use evaluator <- decode.field("evaluator", decode.string)
  decode.success(Identity(build:, seam:, evaluator:))
}

fn origin_decoder() -> decode.Decoder(Origin) {
  use session_id <- decode.field("session", decode.string)
  use strand <- decode.field("strand", decode.string)
  use workspace <- decode.field("workspace", decode.string)
  use parent <- decode.field("parent", decode.optional(decode.string))
  use parent <- decode.then(case parent {
    None -> decode.success(None)
    Some(text) ->
      case candidate_id(text) {
        Ok(id) -> decode.success(Some(id))
        Error(_) -> decode.failure(None, "candidate digest")
      }
  })
  decode.success(Origin(session_id:, strand:, workspace:, parent:))
}

fn file_decoder() -> decode.Decoder(#(String, String)) {
  use path <- decode.field("path", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(#(path, text))
}

fn candidate_decoder() -> decode.Decoder(Candidate) {
  use id <- decode.field("id", digest_decoder(CandidateId))
  use body <- decode.field("candidate", candidate_fields())
  decode.success(Candidate(..body, id:))
}

fn candidate_fields() -> decode.Decoder(Candidate) {
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", kind_decoder())
  use scope <- decode.field("scope", scope_decoder())
  use origin <- decode.field("origin", origin_decoder())
  use identity <- decode.field("identity", identity_decoder())
  use files <- decode.field("files", decode.list(file_decoder()))
  use test_entry <- decode.field("test_entry", decode.optional(decode.string))
  use description <- decode.field("description", decode.string)
  use input_schema <- decode.field("input_schema", decode.string)
  decode.success(Candidate(
    id: placeholder(),
    name:,
    kind:,
    scope:,
    origin:,
    identity:,
    files:,
    test_entry:,
    description:,
    input_schema:,
  ))
}

fn evidence_decoder() -> decode.Decoder(Evidence) {
  use id <- decode.field("id", digest_decoder(EvidenceId))
  use body <- decode.field("evidence", evidence_fields())
  decode.success(Evidence(..body, id:))
}

fn evidence_fields() -> decode.Decoder(Evidence) {
  use candidate_id <- decode.field("candidate_id", digest_decoder(CandidateId))
  use identity <- decode.field("identity", identity_decoder())
  use at_ms <- decode.field("at_ms", decode.int)
  use purpose <- decode.field("purpose", purpose_decoder())
  use verdict <- decode.field("verdict", decode.string)
  use reason <- decode.field("reason", decode.string)
  use verdict <- decode.then(case verdict {
    "passed" -> decode.success(Passed)
    "failed" -> decode.success(Failed)
    "inconclusive" -> decode.success(Inconclusive(reason))
    _ -> decode.failure(Failed, "known verdict")
  })
  use observation <- decode.field("observation", decode.string)
  decode.success(Evidence(
    id: evidence_placeholder(),
    candidate_id:,
    identity:,
    at_ms:,
    purpose:,
    verdict:,
    observation:,
  ))
}

fn kind_decoder() -> decode.Decoder(Kind) {
  use name <- decode.then(decode.string)
  case name {
    "extension" -> decode.success(Extension)
    "program" -> decode.success(Program)
    "prompt" -> decode.success(Prompt)
    _ -> decode.failure(Prompt, "known candidate kind")
  }
}

fn purpose_decoder() -> decode.Decoder(Purpose) {
  use name <- decode.then(decode.string)
  case name {
    "author_tests" -> decode.success(AuthorTests)
    "independent_rollout" -> decode.success(IndependentRollout)
    _ -> decode.failure(AuthorTests, "known evidence purpose")
  }
}

fn kind_name(kind: Kind) -> String {
  case kind {
    Extension -> "extension"
    Program -> "program"
    Prompt -> "prompt"
  }
}

fn digest_decoder(make: fn(String) -> a) -> decode.Decoder(a) {
  use text <- decode.then(decode.string)
  case valid_digest(text) {
    Ok(Nil) -> decode.success(make(text))
    Error(_) -> decode.failure(make(""), "SHA256 hex")
  }
}

fn valid_digest(text: String) -> Result(Nil, String) {
  case
    string.length(text) == 64
    && list.all(string.to_graphemes(text), fn(char) {
      string.contains("0123456789abcdef", char)
    })
  {
    True -> Ok(Nil)
    False -> Error("expected a lowercase SHA256 hex identity")
  }
}

fn digest(text: String) -> String {
  string.drop_start(blob.ref_for(<<text:utf8>>), 7)
}
