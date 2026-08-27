//// The `code_mode` tool: the model writes a *program* instead of a call.
////
//// One tool over one **CodeMode** seam. The model submits a Gleam
//// program; the harness vets it, compiles it hermetically, runs it in a
//// jailed satellite whose only reachable effect is one capability channel
//// back to the broker, and returns one structured result. Ten dependent
//// steps become one execution, and the intermediate payloads stay inside
//// the program instead of landing in the context
//// (`docs/architecture/code-mode.md`).
////
//// ## Which seam a submission is judged against
////
//// There is not one allowlist but two, and a submission is judged
//// against exactly one of them: the **workspace** seam, a program that
//// orchestrates effects, and the **orchestration** seam, a program that
//// orchestrates agents (`docs/architecture/code-mode.md`, "Two seams").
//// Which of them a host serves is the host's decision; which of the ones
//// it serves a *submission* wants is the model's, named in the call's
//// `seam` argument and defaulting to whichever the host put first.
////
//// The choice appears in the schema exactly when there is a choice: a
//// host serving one seam renders neither the argument nor a second
//// import list, so it pays nothing for a decision its model cannot make.
//// A seam this host does not serve is refused in the shell before the
//// pipeline is called, naming the ones it does — never quietly
//// reinterpreted as the other seam, because a submission judged against
//// an allowlist it did not ask for is a refusal the model cannot act on
//// and, in the other direction, a widening nobody chose.
////
//// ## Why a seam rather than a direct call
////
//// `codemode` depends on `tools` — its capability router renders a
//// `tool.Collected` into a `cap_result` — so `tools` cannot depend on
//// `codemode` without drawing a cycle. The pipeline therefore reaches
//// this tool exactly the way the messaging plane reaches `tools/agent`: a
//// record of closures declared here in plain data and filled by the one
//// package that can see both ends (`client/codemode` in production, a
//// fake in tests). Every type crossing the seam is mirrored here rather
//// than imported, which is also what keeps the vocabulary the model reads
//// stable when the pipeline's internal one moves.
////
//// ## In-band repair is the whole point
////
//// Vetting exists so that a program which asks for something it may not
//// have is *refused with an explanation* rather than run. That is only
//// worth anything if the explanation reaches the model: every rejection
//// comes back naming the rule it broke, the offending import or
//// attribute, and the byte offset where one is available, together with
//// the allowlist it was judged against — everything needed to fix the
//// program and resubmit without a human in the loop. A compile error gets
//// the same treatment for the same reason, and it is the cheap signal:
//// Gleam's type checker doubles as the capability-argument validator, so
//// a mistyped `proc.run` is caught before any node spins up.
////
//// Nothing here crashes. A refusal, a type error, a dead satellite and a
//// program that reported its own failure are all ordinary `is_error` tool
//// results — data the model reads and reacts to.
////
//// ## What the result does not claim
////
//// A jail is only as strong as the kernel under it. The seam hands back
//// whatever enforcement report the helper produced for each stage that
//// ran, and the result says out loud when a layer was skipped or when no
//// report came back at all. A tool result must never imply confinement
//// that was not applied.

import broker/exec.{type EnforcementDemand}
import broker/policy.{type SandboxPolicy}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import tools/blob
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The name the model calls this tool by.
pub const tool_name = "code_mode"

// --- what crosses the seam -------------------------------------------------

/// Which of the two seams a submission is judged and routed under.
/// Mirrors `codemode/vet/policy.Seam`, which owns the closed set — two
/// variants and no third, because "which capabilities travel together"
/// is a decision the vetting policy makes and this side only names.
pub type Seam {
  /// `cap/{fs, proc, net, git, lsp, report, task, actor, kv}`: a program
  /// that orchestrates *effects*.
  WorkspaceSeam
  /// `cap/strand` and `cap/report` and nothing else: a program that
  /// orchestrates *agents*.
  OrchestrationSeam
}

/// The name a model names a seam by, in the tool's arguments and in
/// every refusal that has to say which seam a program was judged
/// against.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.seam_name(codemode.WorkspaceSeam) == "workspace"
/// ```
///
pub fn seam_name(seam: Seam) -> String {
  case seam {
    WorkspaceSeam -> "workspace"
    OrchestrationSeam -> "orchestration"
  }
}

/// What one seam offers a submission judged against it.
///
/// Constructor invariants: `allowed_imports` is the vetting allowlist
/// that seam's submissions are actually judged against and
/// `serviced_caps` the capability names that seam's router actually
/// maps, both read off the running policy rather than copied, so the
/// sentence the model is charged for cannot drift from what refuses it.
pub type SeamOffer {
  SeamOffer(
    seam: Seam,
    /// The modules a submission naming this seam may import.
    allowed_imports: List(String),
    /// The capability names this seam's router services today; every
    /// other one compiles and then answers `unsupported_cap`.
    serviced_caps: List(String),
  )
}

/// The seams a host serves: the one a submission that names none is
/// judged against, and any other it will also accept.
///
/// A record with a named `default` rather than a list, so a host cannot
/// offer nothing at all and there is never a question of which seam an
/// unnamed submission gets. The set of *seams* is closed at two
/// (`Seam`), so `alternates` holds at most one useful entry; it is a
/// list only because nothing here needs to know that.
pub type Seams {
  Seams(default: SeamOffer, alternates: List(SeamOffer))
}

/// Every seam this host serves, the default first — the order the tool's
/// description names them in.
///
/// ## Examples
///
/// ```gleam
/// // list.length(codemode.offered(seam.seams)) == 2
/// ```
///
pub fn offered(seams: Seams) -> List(SeamOffer) {
  [seams.default, ..seams.alternates]
}

/// Who is calling and what they submitted, in the driver's own durable
/// coordinates.
///
/// Constructor invariants: every field but `source` and `within_ms` comes
/// from the dispatching `Ctx`, never from the model's arguments —
/// `{op_id, step_id}` in particular *is* the execution identity the broker
/// pools budget under, so a value invented here would mint a second budget
/// and put the execution beyond the reach of the operation's abort.
/// `within_ms` is already clamped to `max_within_ms` when it arrives,
/// and `seam` is one the host actually serves — the shell resolves the
/// model's argument against `CodeMode.seams` and refuses an unserved one
/// before `execute` is ever called.
pub type Request {
  Request(
    /// The submitted program, verbatim.
    source: String,
    /// The seam this submission is judged and routed under.
    seam: Seam,
    /// The strand whose driver dispatched the call.
    strand: String,
    /// The pooled operation id.
    op_id: OpId,
    /// The pooled step id.
    step_id: String,
    /// This call's own index within its step. Carried because a whole
    /// execution shares one `{op_id, step_id}` with every other call in
    /// its batch, so it is the only durable coordinate that tells two
    /// code-mode calls in one step apart — which is what the orchestration
    /// seam derives a child strand's name from.
    source_index: Int,
    /// The workspace root the program runs against.
    workspace: String,
    /// The session base policy this execution is judged against.
    base_policy: SandboxPolicy,
    /// Enforcement strictness demanded of the jailed stages.
    demand: EnforcementDemand,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
    /// The whole execution's wall budget, in milliseconds.
    within_ms: Int,
  )
}

/// The rule a vetting rejection is charged against. Mirrors
/// `codemode/vet.Rule`.
pub type Rule {
  /// An `@external` — or any attribute, the whole class failing closed —
  /// appeared in the submitted source.
  NoForeignInterface
  /// An import named a module that is not a byte-identical reference to an
  /// allowlisted one.
  ImportNotAllowed
  /// The source did not parse. A malformed program is a rejection, not a
  /// crash.
  Unparseable
}

/// Where in the submitted program a rejection sits. Mirrors
/// `codemode/vet.Location`: imports and attributes on non-function
/// definitions carry no span, so those rejections are `Unlocated` and name
/// the offending construct in the detail instead.
pub type Location {
  /// A byte span `[start, end)` in the submitted source.
  SourceSpan(start: Int, end: Int)
  /// A single byte offset (a parse error reports a point, not a span).
  SourcePoint(byte_offset: Int)
  /// No span is available; the detail names the construct.
  Unlocated
}

/// One vetting violation, phrased so the model can repair the program.
pub type Rejection {
  Rejection(rule: Rule, detail: String, location: Location)
}

/// Why a vetted program produced no artifact. Mirrors
/// `codemode/compile.CompileError`.
pub type CompileFailure {
  /// The hermetic workspace could not be prepared. A harness-side fault,
  /// not the program's doing.
  WorkspaceSetupFailed(reason: String)
  /// The compiler rejected the program: a type error or any other build
  /// diagnostic. The one failure the model can always act on.
  BuildRejected(diagnostics: String)
  /// The build could not be run at all — the jail refused it or the helper
  /// died.
  BuildUnavailable(reason: String)
  /// The build claimed success but produced no usable `.beam` set.
  ArtifactIncomplete(reason: String)
}

/// Why a compiled program returned no outcome. Narrows
/// `codemode/satellite.RunError` to the four cases that read differently
/// to a model, keeping the pipeline's own reason text verbatim.
pub type RunFailure {
  /// The wall deadline passed; the satellite was killed as a unit.
  DeadlineExceeded
  /// The satellite died before it reported an outcome.
  SatelliteGone(reason: String)
  /// The execution never started — the token, the host actor, or the
  /// launch itself.
  StartFailed(reason: String)
  /// The capability channel or the terminal frame broke protocol.
  ChannelFaulted(reason: String)
}

/// The structured result a program returns. Mirrors `cap/report.Outcome`
/// as `codemode/satellite` decodes it.
pub type Outcome {
  /// The program finished with this structured value.
  Completed(value: MsgPackValue)
  /// The program failed in a controlled way and said why.
  Errored(message: String, details: MsgPackValue)
}

/// What one jailed stage's helper reported about the layers it actually
/// applied — or why no such report exists. `Unreported` is never a claim
/// that the stage was confined; it is the seam saying, in as many words,
/// that it does not know.
pub type Report {
  /// The helper's ground truth: the layers it applied, the ones it
  /// skipped (`skipped`, named without their `skip:` prefix), and whether
  /// the run counts as degraded.
  Enforced(applied: List(String), skipped: List(String), degraded: Bool)
  /// This stage produced no report, and this is why.
  Unreported(reason: String)
}

/// What the kernel enforced on each of an execution's two jailed stages.
///
/// A record rather than a list, so neither stage can go unmentioned: a
/// seam that named one and omitted the other is exactly what made a green
/// code-mode run unable to prove its jail engaged (issue #5).
pub type Enforcement {
  Enforcement(build: Report, node: Report)
}

/// How far the pipeline got, and what it produced.
pub type ExecResult {
  /// Vetting refused the program; nothing was compiled or run.
  VetRejected(rejections: List(Rejection))
  /// The program vetted but did not compile.
  CompileFailed(failure: CompileFailure)
  /// The program compiled but the satellite returned no outcome.
  RunFailed(failure: RunFailure)
  /// The program ran. `manifest_hash` is the artifact's content address,
  /// the durable fingerprint of exactly what executed.
  Ran(outcome: Outcome, manifest_hash: String)
}

/// One whole execution: how it settled, and what the kernel really did to
/// each stage of it.
pub type Execution {
  Execution(result: ExecResult, enforcement: Enforcement)
}

/// The code-mode seam: everything this tool may do, as data.
///
/// Constructor invariants: `execute` is total — every failure of every
/// stage is a value in the `Execution` it returns, and it runs the
/// execution under the `Request`'s own `{op_id, step_id}` rather than
/// minting an identity of its own. `seams` names every seam this host
/// serves and, for each, the allowlist a submission naming it is judged
/// against and the capabilities its router maps — published rather than
/// copied, so the sentence the model is charged for on every request
/// cannot drift from the policy the program is judged against.
/// `default_within_ms` is at most `max_within_ms`.
pub type CodeMode {
  CodeMode(
    /// Runs one submitted program end to end.
    execute: fn(Request) -> Execution,
    /// The seams this host serves, the default first.
    seams: Seams,
    /// The wall budget used when the call names none.
    default_within_ms: Int,
    /// The ceiling a call's `within_ms` is clamped to.
    max_within_ms: Int,
  )
}

/// A host that serves one seam, which is every host until one wires a
/// messaging plane behind the orchestration router.
///
/// ## Examples
///
/// ```gleam
/// // codemode.one_seam(offer).alternates == []
/// ```
///
pub fn one_seam(offer: SeamOffer) -> Seams {
  Seams(default: offer, alternates: [])
}

// --- the tool --------------------------------------------------------------

/// The `code_mode` tool over one seam, as a one-element list so a registry
/// can `list.append` it the way it appends the agent family.
///
/// Registration is gated on a seam existing at all rather than on the tool
/// refusing at call time, and the reason is arithmetic rather than
/// tidiness: the wire tool array is built from the registry, renders ahead
/// of the system prompt, and is the byte prefix of the provider's cached
/// region — so a permanently-refusing definition is paid for on every
/// request of every strand for the life of the session. A host that wired
/// no pipeline simply has no `code_mode`.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(core_tools, codemode.tools(seam)))
/// ```
///
pub fn tools(mode: CodeMode) -> List(Tool) {
  [tool_for(mode)]
}

/// The `code_mode` tool itself.
///
/// `replay: tool.Never` is not a hedge. A program's capability calls are
/// arbitrary external effects — a process run, a file written — and
/// nothing about resubmitting the same source makes them idempotent: there
/// is no minted identifier to reconcile onto, the way `agent_spawn` has
/// one, and no digest-bound pre-image, the way `fs_edit` has one. A crash
/// mid-execution must therefore synthesize an interrupted result rather
/// than run the program a second time. `execution_mode: tool.Exclusive`
/// for two reasons: a program may mutate the workspace, and the broker
/// pools budget per `{op_id, step_id}` — a concurrent call in the same
/// step would open that ledger with *its* budget, and a satellite needs
/// two outstanding effects to exist at all.
///
/// ## Examples
///
/// ```gleam
/// // codemode.tool_for(seam).name == codemode.tool_name
/// ```
///
pub fn tool_for(mode: CodeMode) -> Tool {
  tool.Tool(
    name: tool_name,
    description: description(mode),
    schema: tool.object_schema(
      list.flatten([
        [
          #(
            "program",
            tool.string_property(
              "the Gleam program. It must define `pub fn main() -> "
              <> "report.Outcome` and import `cap/report` to build one",
            ),
          ),
        ],
        seam_properties(mode.seams),
        [
          #(
            "within_ms",
            tool.integer_property(
              "wall budget for the whole execution — compile included; "
              <> "default "
              <> int.to_string(mode.default_within_ms)
              <> ", clamped to "
              <> int.to_string(mode.max_within_ms),
            ),
          ),
        ],
      ]),
      ["program"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements:,
    run: fn(ctx, args) { run(mode, ctx, args) },
  )
}

// The `seam` argument exists exactly when this host serves more than one
// seam. A single-seam host renders no property at all rather than an
// enum of one: the schema is part of the tool bytes, which render ahead
// of the system prompt and are the byte prefix of the provider's cached
// region, so an argument with one legal value would be paid for on every
// request of every strand to tell the model about a decision it cannot
// make.
fn seam_properties(seams: Seams) -> List(#(String, JsonValue)) {
  case seams.alternates {
    [] -> []
    _alternates -> [
      #(
        "seam",
        tool.enum_property(
          list.map(offered(seams), fn(offer) { seam_name(offer.seam) }),
          "which seam to judge and run this program under; default `"
            <> seam_name(seams.default.seam)
            <> "`",
        ),
      ),
    ]
  }
}

/// The model-facing description: what to write, which seams this host
/// serves and what each may import, what is actually serviced, and what
/// comes back when a program is refused.
///
/// Every list here is read off the seam rather than copied, so the
/// sentence the model is charged for on every request cannot drift from
/// the policy the program is judged against.
///
/// ## The size decision, since a description is a cache prefix
///
/// Tool bytes render *before* the system prompt and are the byte prefix
/// of the provider's cached region, so a word added here is paid on every
/// request of every strand for the life of the session. Two seams could
/// therefore have been handled by naming the seams and leaving both
/// import lists to the rejection — the model guesses, is refused in band
/// by a pure vetting pass, and repairs. That was rejected. The wrong
/// guess costs a whole submission: a provider round trip and several
/// hundred *output* tokens to write a program against an import surface
/// the model was never shown, and the description is the only place it
/// could have learned that surface before writing. Cached prefix bytes
/// are the cheapest tokens in the ledger and generated tokens the
/// dearest, so paying the prefix once beats paying a rewrite per
/// unfamiliar program.
///
/// Two full lists were rejected too, and for a plainer reason: the seams
/// differ only in their `cap/*` modules and share the whole pure
/// standard-library subset, so printing both in full duplicates a dozen
/// module names and hands the model two long lists to diff for the
/// difference that matters. The shared part is therefore stated once and
/// each seam names only what it adds — derived from the offers rather
/// than asserted, so it cannot go stale. A host serving one seam renders
/// exactly the sentence it rendered before seams were selectable: the
/// extra bytes are paid by the hosts that actually offer the choice.
///
/// ## Examples
///
/// ```gleam
/// // string.contains(codemode.description(mode), "cap/report")
/// ```
///
pub fn description(mode: CodeMode) -> String {
  "Run a Gleam program in a jailed satellite and get one structured "
  <> "result. Use it instead of a chain of tool calls when the steps "
  <> "depend on each other: loops, conditionals, and concurrency happen "
  <> "inside the program, and only what `main` returns comes back — the "
  <> "intermediate output never enters the conversation. Write `pub fn "
  <> "main() -> report.Outcome`, returning `report.text(...)` or "
  <> "`report.value(...)`. "
  <> seams_text(mode.seams)
  <> " A program that is refused or does not compile comes back with the "
  <> "reason, so you can fix it and submit again."
}

// One seam: the sentence this tool has always rendered.
fn seams_text(seams: Seams) -> String {
  case seams.alternates {
    [] ->
      "Imports are restricted to: "
      <> joined(seams.default.allowed_imports)
      <> ". `@external` is refused. Capabilities serviced today: "
      <> joined(seams.default.serviced_caps)
      <> "; the other `cap/*` modules compile but answer unsupported_cap."
    _alternates -> many_seams_text(seams)
  }
}

// More than one: name them, say which is the default, and state the
// shared import subset once instead of twice.
fn many_seams_text(seams: Seams) -> String {
  let offers = offered(seams)
  let shared = shared_imports(offers)
  let clauses =
    offers
    |> list.map(fn(offer) { seam_clause(offer, shared) })
    |> string.join(" ")
  int.to_string(list.length(offers))
  <> " seams, named by `seam` and defaulting to `"
  <> seam_name(seams.default.seam)
  <> "`; a program is judged against exactly the one it names. "
  <> clauses
  <> case shared {
    [] -> ""
    modules -> " Every seam also allows: " <> joined(modules) <> "."
  }
  <> " `@external` is refused, and the `cap/*` modules the named seam "
  <> "does not service compile but answer unsupported_cap."
}

fn seam_clause(offer: SeamOffer, shared: List(String)) -> String {
  "`"
  <> seam_name(offer.seam)
  <> "` adds imports: "
  <> joined(
    list.filter(offer.allowed_imports, fn(module) {
      !list.contains(shared, module)
    }),
  )
  <> "; capabilities serviced: "
  <> joined(offer.serviced_caps)
  <> "."
}

// The modules every offered seam allows. Derived rather than declared:
// the seams' pure standard-library subset is the same list today, and a
// description that asserted so would be a claim nothing checks.
fn shared_imports(offers: List(SeamOffer)) -> List(String) {
  case offers {
    [] -> []
    [first, ..rest] ->
      list.filter(first.allowed_imports, fn(module) {
        list.all(rest, fn(offer) {
          list.contains(offer.allowed_imports, module)
        })
      })
  }
}

fn joined(names: List(String)) -> String {
  string.join(list.sort(names, string.compare), ", ")
}

/// What a code-mode execution needs of the session base: the workspace
/// writable (the hermetic build root and the cap-channel handles live
/// under it) and the whole filesystem readable, since the Gleam and Erlang
/// toolchains the build and the node need are outside it.
///
/// Declarative only. This tool clears nothing through `Ctx.clear_call`:
/// the build and the node are cleared inside the pipeline, each against
/// its own far narrower requirements, and each refused in band when the
/// session base cannot cover them.
///
/// ## Examples
///
/// ```gleam
/// // codemode.requirements("/work").writable_roots == ["/work"]
/// ```
///
pub fn requirements(workspace: String) -> SandboxPolicy {
  let base = policy.workspace_default(workspace)
  policy.SandboxPolicy(..base, readable_roots: ["/"], env_allow: [])
}

fn run(mode: CodeMode, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use program <- tool.with_arg(tool.required_string(args, "program"))
  use within_ms <- tool.with_arg(tool.optional_int(args, "within_ms"))
  use named <- tool.with_arg(tool.optional_string(args, "seam"))
  use offer <- tool.with_arg(chosen_seam(mode.seams, named))
  case string.trim(program) {
    "" -> tool.failure("invalid arguments: `program` must not be empty")
    _ ->
      mode.execute(request(mode, ctx, program, within_ms, on: offer.seam))
      |> render(ctx, offer, _)
  }
}

// The seam a call is judged under: the one it named, when this host
// serves it, and the host's default when it named none. An unserved seam
// and an unknown name answer the same way and say what is on offer —
// there is nothing to gain by telling a model that a seam it cannot use
// exists somewhere, and nothing but harm in judging its program against
// an allowlist it did not ask for.
fn chosen_seam(
  seams: Seams,
  named: Option(String),
) -> Result(SeamOffer, String) {
  case named {
    option.None -> Ok(seams.default)
    option.Some(name) ->
      offered(seams)
      |> list.find(fn(offer) { seam_name(offer.seam) == name })
      |> result.map_error(fn(_missing) {
        "`seam` must be one of: "
        <> joined(list.map(offered(seams), fn(offer) { seam_name(offer.seam) }))
      })
  }
}

/// The request one call sends across the seam: the submitted program,
/// the resolved seam and the clamped budget, and otherwise nothing the
/// model supplied.
///
/// ## Examples
///
/// ```gleam
/// // codemode.request(mode, ctx, source, None, on: seam).op_id == ctx.op_id
/// ```
///
pub fn request(
  mode: CodeMode,
  ctx: Ctx,
  source: String,
  within_ms: Option(Int),
  on seam: Seam,
) -> Request {
  Request(
    source:,
    seam:,
    strand: ctx.strand,
    op_id: ctx.op_id,
    step_id: ctx.step_id,
    source_index: ctx.source_index,
    workspace: ctx.workspace,
    base_policy: ctx.base_policy,
    demand: ctx.demand,
    env: ctx.env,
    within_ms: int.clamp(
      option.unwrap(within_ms, mode.default_within_ms),
      min: 1,
      max: mode.max_within_ms,
    ),
  )
}

// --- rendering the execution ----------------------------------------------

// One `ToolOutcome` per execution, never a stream. `execute` is one
// synchronous pipeline with one settlement, and the point of code mode is
// that the steps inside it stay inside it — a stream of intermediates
// would put back exactly the context traffic the feature removes.
fn render(ctx: Ctx, offer: SeamOffer, execution: Execution) -> ToolOutcome {
  case execution.result {
    VetRejected(rejections:) -> vet_outcome(offer, rejections)
    CompileFailed(failure:) -> compile_outcome(ctx, execution, failure)
    RunFailed(failure:) -> run_failed_outcome(execution, failure)
    Ran(outcome:, manifest_hash:) ->
      ran_outcome(ctx, execution, outcome, manifest_hash)
  }
}

// A rejection is a repair brief: every violation in one pass, each with
// its rule, its offending construct and its offset, and the allowlist it
// was judged against so the fix does not need a second round trip.
//
// The seam is named unconditionally, in the heading and in the details,
// because a model that asked for one seam and reads a refusal that could
// have come from either has no way to tell a program it must repair from
// a submission it must re-aim. Thirty bytes, on a path that is already a
// failure, buys that.
fn vet_outcome(offer: SeamOffer, rejections: List(Rejection)) -> ToolOutcome {
  let judged =
    "the program was refused before it ran, judged against the `"
    <> seam_name(offer.seam)
    <> "` seam; "
  let heading = case list.length(rejections) {
    1 -> judged <> "one rule was broken:"
    count -> judged <> int.to_string(count) <> " rules were broken:"
  }
  let body =
    [
      [heading],
      list.map(rejections, rejection_text),
      case list.any(rejections, is_import_rejection) {
        False -> []
        True -> [
          "the imports a program may use on the `"
          <> seam_name(offer.seam)
          <> "` seam are: "
          <> joined(offer.allowed_imports),
        ]
      },
      case list.any(rejections, is_parse_rejection) {
        False -> []
        True -> [parser_note]
      },
      ["fix the program and submit it again."],
    ]
    |> list.flatten
    |> string.join("\n")
  tool.failure(body)
  |> tool.with_details(
    json.Object([
      #("status", json.String("vetting_rejected")),
      #("seam", json.String(seam_name(offer.seam))),
      #("rejections", json.Array(list.map(rejections, rejection_json))),
      #(
        "allowed_imports",
        json.Array(
          list.sort(offer.allowed_imports, string.compare)
          |> list.map(json.String),
        ),
      ),
    ]),
  )
}

/// What a parse rejection adds: the one way a program can be legal Gleam
/// and still fail to parse here.
///
/// Vetting reads the submission with `glance`, a standalone parser rather
/// than the compiler's own, and `glance` 1.1 does not accept label
/// shorthand — in a call or in a pattern — though `gleam build` does. So
/// a submitted program is held to a slightly narrower language than the
/// one that will compile it, and the difference surfaces as an
/// `Unparseable` rejection at a byte offset for syntax that is perfectly
/// legal. It is stated here rather than in the tool description for the
/// reason every byte of that description is argued over: this is where
/// someone actually hits it, and a reader who never writes the shorthand
/// never pays for the sentence.
pub const parser_note = "note: vetting parses the submission with a standalone parser that accepts a slightly narrower Gleam than the compiler. Label shorthand — `f(value:)` in a call, `Pending(handle:, waited_ms:)` in a pattern — does not parse here; write each label's value out."

fn is_import_rejection(rejection: Rejection) -> Bool {
  rejection.rule == ImportNotAllowed
}

fn is_parse_rejection(rejection: Rejection) -> Bool {
  rejection.rule == Unparseable
}

fn rejection_text(rejection: Rejection) -> String {
  "- "
  <> rule_text(rejection.rule)
  <> ": "
  <> rejection.detail
  <> location_text(rejection.location)
}

fn rule_text(rule: Rule) -> String {
  case rule {
    NoForeignInterface -> "foreign interface"
    ImportNotAllowed -> "import not allowed"
    Unparseable -> "does not parse"
  }
}

fn location_text(location: Location) -> String {
  case location {
    SourceSpan(start:, end:) ->
      " [bytes " <> int.to_string(start) <> "-" <> int.to_string(end) <> "]"
    SourcePoint(byte_offset:) -> " [byte " <> int.to_string(byte_offset) <> "]"
    Unlocated -> ""
  }
}

fn rejection_json(rejection: Rejection) -> JsonValue {
  let located = case rejection.location {
    SourceSpan(start:, end:) -> [
      #("start", json.Int(start)),
      #("end", json.Int(end)),
    ]
    SourcePoint(byte_offset:) -> [#("byte_offset", json.Int(byte_offset))]
    Unlocated -> []
  }
  json.Object(list.append(
    [
      #("rule", json.String(rule_key(rejection.rule))),
      #("detail", json.String(rejection.detail)),
    ],
    located,
  ))
}

fn rule_key(rule: Rule) -> String {
  case rule {
    NoForeignInterface -> "no_foreign_interface"
    ImportNotAllowed -> "import_not_allowed"
    Unparseable -> "unparseable"
  }
}

// The compiler's own diagnostics, verbatim: a type error is the cheapest
// precise signal in the whole pipeline and the model can act on it
// directly. Large diagnostics overflow to the blob store like any other
// oversized tool output (spec §3.2).
fn compile_outcome(
  ctx: Ctx,
  execution: Execution,
  failure: CompileFailure,
) -> ToolOutcome {
  let #(kind, body) = case failure {
    BuildRejected(diagnostics:) -> #(
      "build_rejected",
      "the program did not compile:\n" <> diagnostics,
    )
    WorkspaceSetupFailed(reason:) -> #(
      "workspace_setup_failed",
      "the code-mode build workspace could not be prepared: " <> reason,
    )
    BuildUnavailable(reason:) -> #(
      "build_unavailable",
      "the code-mode build could not run: " <> reason,
    )
    ArtifactIncomplete(reason:) -> #(
      "artifact_incomplete",
      "the build produced no usable artifact: " <> reason,
    )
  }
  let details =
    json.Object([
      #("status", json.String("compile_failed")),
      #("kind", json.String(kind)),
      #("detail", json.String(compile_detail(failure))),
      #("sandbox", enforcement_json(execution.enforcement)),
    ])
  bounded_failure(ctx, body <> "\n" <> sandbox_text(execution), details)
}

fn compile_detail(failure: CompileFailure) -> String {
  case failure {
    BuildRejected(diagnostics:) -> diagnostics
    WorkspaceSetupFailed(reason:) -> reason
    BuildUnavailable(reason:) -> reason
    ArtifactIncomplete(reason:) -> reason
  }
}

fn run_failed_outcome(
  execution: Execution,
  failure: RunFailure,
) -> ToolOutcome {
  let #(kind, body) = case failure {
    DeadlineExceeded -> #(
      "deadline_exceeded",
      "the program ran past its wall budget and the satellite was killed. "
        <> "Nothing it had not already reported survives. Submit a program "
        <> "that does less, or raise `within_ms`.",
    )
    SatelliteGone(reason:) -> #(
      "satellite_gone",
      "the satellite died before the program reported an outcome: " <> reason,
    )
    StartFailed(reason:) -> #(
      "start_failed",
      "the code-mode execution could not start: " <> reason,
    )
    ChannelFaulted(reason:) -> #(
      "channel_faulted",
      "the satellite's capability channel broke protocol: " <> reason,
    )
  }
  tool.failure(body <> "\n" <> sandbox_text(execution))
  |> tool.with_details(
    json.Object([
      #("status", json.String("run_failed")),
      #("kind", json.String(kind)),
      #("detail", json.String(run_failure_detail(failure))),
      #("sandbox", enforcement_json(execution.enforcement)),
    ]),
  )
}

fn run_failure_detail(failure: RunFailure) -> String {
  case failure {
    DeadlineExceeded -> "the wall deadline passed"
    SatelliteGone(reason:) -> reason
    StartFailed(reason:) -> reason
    ChannelFaulted(reason:) -> reason
  }
}

// The program ran. A `Completed` text value is handed over verbatim —
// `report.text` is the common case and quoting it as JSON would only make
// it harder to read — and every other value is rendered as JSON. An
// `Errored` outcome is the program's own controlled failure, so it is an
// `is_error` result: something for the model to react to, not a fault.
fn ran_outcome(
  ctx: Ctx,
  execution: Execution,
  outcome: Outcome,
  manifest_hash: String,
) -> ToolOutcome {
  let #(status, is_error, body, payload) = case outcome {
    Completed(value:) -> #("completed", False, value_text(value), [
      #("value", value_json(value)),
    ])
    Errored(message:, details:) -> #(
      "program_failed",
      True,
      "the program reported a failure: "
        <> message
        <> case details {
        msgpack.NilValue -> ""
        other -> "\ndetails: " <> value_text(other)
      },
      [
        #("message", json.String(message)),
        #("details", value_json(details)),
      ],
    )
  }
  let details =
    json.Object(
      list.flatten([
        [#("status", json.String(status))],
        payload,
        [
          #("manifest_hash", json.String(manifest_hash)),
          #("sandbox", enforcement_json(execution.enforcement)),
        ],
      ]),
    )
  let text = body <> "\n" <> sandbox_text(execution)
  case is_error {
    True -> bounded_failure(ctx, text, details)
    False -> bounded_success(ctx, text, details)
  }
}

// --- saying what actually ran ---------------------------------------------

/// What the running kernel really enforced, as one line the model can
/// read.
///
/// Both stages are always named, so there is no absence to misread: a
/// stage that reported nothing says why instead of going missing, a
/// skipped layer is listed as skipped rather than folded in with the
/// applied ones, and a degraded stage says so outright. A tool result must
/// never imply a jail that was not applied.
///
/// ## Examples
///
/// ```gleam
/// // string.starts_with(codemode.sandbox_text(execution), "sandbox: ")
/// ```
///
pub fn sandbox_text(execution: Execution) -> String {
  "sandbox: "
  <> stage_text(build_stage, execution.enforcement.build)
  <> "; "
  <> stage_text(satellite_stage, execution.enforcement.node)
  <> "."
}

/// The stage label for the hermetic build.
pub const build_stage = "the hermetic build"

/// The stage label for the jailed satellite node.
pub const satellite_stage = "the satellite node"

fn stage_text(stage: String, report: Report) -> String {
  case report {
    Unreported(reason:) ->
      stage
      <> " made NO enforcement report ("
      <> reason
      <> "), which is not a claim that it was confined"
    Enforced(applied:, skipped:, degraded:) ->
      stage
      <> " enforced ["
      <> string.join(applied, ", ")
      <> "]"
      <> case skipped {
        [] -> ""
        missing -> ", SKIPPED [" <> string.join(missing, ", ") <> "]"
      }
      <> case degraded {
        True -> " (DEGRADED: the kernel did not provide every demanded layer)"
        False -> ""
      }
  }
}

fn enforcement_json(reports: Enforcement) -> JsonValue {
  json.Object([
    #("build", stage_json(reports.build)),
    #("node", stage_json(reports.node)),
  ])
}

fn stage_json(report: Report) -> JsonValue {
  case report {
    Unreported(reason:) ->
      json.Object([
        #("reported", json.Bool(False)),
        #("reason", json.String(reason)),
      ])
    Enforced(applied:, skipped:, degraded:) ->
      json.Object([
        #("reported", json.Bool(True)),
        #("enforced", json.Array(list.map(applied, json.String))),
        #("skipped", json.Array(list.map(skipped, json.String))),
        #("degraded", json.Bool(degraded)),
      ])
  }
}

// --- values ----------------------------------------------------------------

/// A program's structured value as text: a plain string verbatim,
/// anything else as JSON.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.value_text(msgpack.StringValue("hi")) == "hi"
/// ```
///
pub fn value_text(value: MsgPackValue) -> String {
  case value {
    msgpack.StringValue(value:) -> value
    other -> json.to_string(value_json(other))
  }
}

/// A program's structured value as JSON, so the details field carries it
/// in the vocabulary the rest of a tool result speaks.
///
/// Total over every msgpack shape. Binary becomes a byte-count note
/// because JSON has no bytes and inventing an encoding would let a
/// reader mistake the note for the content; a map with non-string keys
/// renders each key with the same rules, so no entry is silently dropped.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.value_json(msgpack.IntValue(3)) == json.Int(3)
/// ```
///
pub fn value_json(value: MsgPackValue) -> JsonValue {
  case value {
    msgpack.NilValue -> json.Null
    msgpack.BoolValue(value:) -> json.Bool(value)
    msgpack.IntValue(value:) -> json.Int(value)
    msgpack.FloatValue(value:) -> json.Float(value)
    msgpack.StringValue(value:) -> json.String(value)
    msgpack.BinaryValue(bytes:) ->
      json.String(
        "<" <> int.to_string(bit_array.byte_size(bytes)) <> " bytes of binary>",
      )
    msgpack.ArrayValue(items:) -> json.Array(list.map(items, value_json))
    msgpack.MapValue(entries:) ->
      json.Object(
        list.map(entries, fn(entry) {
          #(key_text(entry.0), value_json(entry.1))
        }),
      )
  }
}

fn key_text(key: MsgPackValue) -> String {
  case key {
    msgpack.StringValue(value:) -> value
    other -> json.to_string(value_json(other))
  }
}

// --- bounded results -------------------------------------------------------

// A program's value and a compiler's diagnostics are both unbounded, so
// both go through the blob overflow the other tools use (spec §3.2). A
// blob-store failure falls back to the inline body rather than losing the
// result.
fn bounded_success(ctx: Ctx, text: String, details: JsonValue) -> ToolOutcome {
  bounded(ctx, text, details, False)
}

fn bounded_failure(ctx: Ctx, text: String, details: JsonValue) -> ToolOutcome {
  bounded(ctx, text, details, True)
}

fn bounded(
  ctx: Ctx,
  text: String,
  details: JsonValue,
  is_error: Bool,
) -> ToolOutcome {
  case blob.bound(ctx, text) {
    Error(_error) ->
      tool.ToolOutcome(
        content: [tool.text_block(text)],
        details: option.Some(details),
        is_error:,
      )
    Ok(bounded) ->
      tool.ToolOutcome(
        content: [tool.text_block(blob.bounded_text(bounded))],
        details: option.Some(details),
        is_error:,
      )
      |> blob.with_blob_details(bounded)
  }
}
