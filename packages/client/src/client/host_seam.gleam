//// A code-mode seam a host defines for its own sessions
//// (protocol-change/111).
////
//// Loom's code mode judges a program against one of its own seams, a closed
//// set of `cap/*` modules a host selects from (`codemode/vet/policy.Seam`),
//// widened by the doors the host wired: MCP servers, a language server, a
//// blackboard. A host that embeds Loom for a narrower job needs two more
//// things, and this module is both.
////
//// - **A narrower allowlist.** `HostSeam.imports` names the `cap/*` modules a
////   program of this session may import. It only narrows: a module the seam
////   would not have admitted stays out, so a host cannot hand a program a
////   module whose door it never wired. `HostSeam.withheld` names capability
////   calls refused even though their module is admitted, which is how a host
////   keeps `cap/lsp`'s queries and drops its `lsp.rename`.
//// - **A module of its own.** `HostModule` is a module name and a list of the
////   host's own tools. Loom generates `cap/<name>` from them with the same
////   generator that builds `cap/mcp/<server>` (`mcp/codegen.generate_host`),
////   vendors it into the program's prelude, and shows its types in the
////   `code_mode` description.
////
//// ## A host function is a host tool
////
//// Each function of a host module is a `tool.Tool` the host also registers
//// as a direct tool. A call `aegis.post_note(..)` crosses the capability
//// channel as `host.aegis` with the tool's name and its JSON arguments, and
//// this module's router answers it by asking the strand's tool list for that
//// tool (`codemode/tool_gate.holding`, the question a direct call is held
//// to) and then running the tool's own `run` on the arguments. The decoder,
//// the host's checks and the refusal are therefore the direct tool's, and so
//// is what the program reads: an in-band failure is `cap/mcp.ToolFailed`
//// carrying the tool's own text. The seam changes how a tool is called and
//// never what it may do.
////
//// ## Where it is answered
////
//// A session whose workspace is in this VM composes the router into its own
//// execution (`client/codemode.over_host`). A session whose workspace is on
//// an executor runs the program there, beside the checkout, and the executor
//// holds no host tool. It is handed the plan (imports, withheld names and the
//// generated module, never a tool) and builds `elsewhere` from it, and every
//// `host.<module>` call is owner-bound (`client/cap_placement`): it returns
//// to the session's owner, which answers it from this router. Because an
//// executor may be untrusted (protocol-change/109), the owner does not take
//// the executor's word for the seam either: `owner_admits` refuses an
//// owner-bound call whose module the host's imports exclude, so a hostile
//// executor cannot reach `strand.*` on a session whose host never offered it.
////
//// ## What a host cannot do with it
////
//// Widen a seam, name a module that shadows a shipped `cap/*` module, or
//// reach anything but its own tools. The generated module is source a host
//// chose and a model reads, so it passes the same sanitizer, bounds and `@`
//// backstop an MCP server's listing does.

import broker/framing.{type CapOutcome}
import client/mcp as mcp_wiring
import codemode/identity
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, CapDenial,
}
import codemode/tool_gate
import codemode/vet/policy as vet_policy
import core/json.{type JsonValue}
import core/message
import core/msgpack.{type MsgPackValue}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam_mcp/json as mcp_json
import gleam_mcp/protocol as mcp_protocol
import mcp/codegen
import mcp/interchange
import mcp/name as mcp_name
import tools/agent.{type Caller, type Refusal}
import tools/tool

/// What a host declares for one session's code mode.
pub type HostSeam {
  HostSeam(
    /// The `cap/*` modules a program may import, a subset of what the seam
    /// would admit. An MCP façade is named by its generated module, the
    /// server's name mangled as `mcp/name` does, which is not checked here
    /// because the MCP layer is not known when the seam is built. A module
    /// named here that the seam does not admit stays out; a module the seam
    /// admits and this list omits is refused at vetting. Standard-library
    /// modules are not affected.
    imports: List(String),
    /// Capability names refused even though their module is admitted, such
    /// as `lsp.rename`. They are removed from what the description says the
    /// router services, and a call to one is refused in band.
    withheld: List(String),
    /// The host's own module, if it declares one.
    module: Option(HostModule),
  )
}

/// A module of the host's own tools, `cap/<name>`.
pub type HostModule {
  HostModule(
    /// The module's last segment: `aegis` names `cap/aegis` and the
    /// capability `host.aegis`. A lower-case Gleam identifier that is not a
    /// shipped `cap/*` module.
    name: String,
    /// The module's functions, one per tool.
    functions: List(HostFunction),
  )
}

/// One function of a host module: a tool the host also offers directly, and
/// the JSON schema of its result, when the tool reports a typed one.
pub type HostFunction {
  HostFunction(
    /// The tool. Its name is the function's wire name, its description the
    /// function's documentation, its schema the function's arguments and its
    /// `run` the answer.
    tool: tool.Tool,
    /// The schema of the tool's `details` on success. With one, the
    /// generated function returns a decoded value; without one it returns
    /// `cap/mcp.ToolResult`, whose text is the tool's.
    output: Option(JsonValue),
  )
}

/// A host seam ready for code mode: the declaration checked and its module
/// generated, or a seam an executor was handed by the session's owner.
pub opaque type Layer {
  Layer(
    imports: List(String),
    withheld: List(String),
    module: Option(Generated),
  )
}

/// A host module as code mode carries it: its name, the generated source and
/// surface, and who answers its calls.
type Generated {
  Generated(name: String, generated: codegen.Generated, answer: Answer)
}

/// Who answers a host module's calls.
type Answer {
  /// This VM holds the tools and runs them.
  Here(functions: List(HostFunction))

  /// The session's owner holds them; calls are sent there.
  Elsewhere
}

/// The capability family every host module's calls travel under.
pub const cap_prefix = "host."

/// The module a host module's functions return the vocabulary of. A program
/// that matches on a refusal imports it, so a seam with a host module admits
/// it beside the module.
pub const vocabulary_module = "cap/mcp"

/// The denial code of a call to a withheld capability, or to a capability
/// whose module the host's seam does not admit.
pub const withheld_code = "unsupported_cap"

/// Checks a host's declaration and generates its module.
///
/// Refused, with a sentence naming the problem: an import that is not a
/// shipped `cap/*` module or an MCP façade, a module name that is not a
/// lower-case identifier or that names a shipped module, two functions over
/// one tool, and anything `mcp/codegen` refuses (bounds, collisions, the
/// sanitizer).
///
/// ## Examples
///
/// ```gleam
/// // host_seam.build(host_seam.HostSeam(
/// //   imports: ["cap/search", "cap/report"],
/// //   withheld: [],
/// //   module: option.Some(host_seam.HostModule("aegis", functions)),
/// // ))
/// ```
///
pub fn build(seam: HostSeam) -> Result(Layer, String) {
  use Nil <- result.try(list.try_each(seam.imports, known_import))

  // A seam with no module of its own still narrows.
  case seam.module {
    None ->
      Ok(Layer(imports: seam.imports, withheld: seam.withheld, module: None))
    Some(module) -> {
      use generated <- result.map(generate(module))
      Layer(
        imports: seam.imports,
        withheld: seam.withheld,
        module: Some(generated),
      )
    }
  }
}

/// The layer of a session whose host module is answered by its owner: what
/// an executor builds from the plan the owner sent it.
///
/// `module` is the module's name with its generated source and surface,
/// exactly as `plan_module` gave them. No tool crosses, so nothing here can
/// answer a call; `client/owner_codemode` sends every `host.` call to the
/// owner before this layer's router would see it.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.elsewhere(["cap/search"], ["lsp.rename"], option.None)
/// ```
///
pub fn elsewhere(
  imports: List(String),
  withheld: List(String),
  module: Option(#(String, codegen.Generated)),
) -> Layer {
  Layer(
    imports:,
    withheld:,
    module: option.map(module, fn(pair) {
      Generated(name: pair.0, generated: pair.1, answer: Elsewhere)
    }),
  )
}

/// The imports a layer admits, as declared.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.imports(layer) == ["cap/search"]
/// ```
pub fn imports(layer: Layer) -> List(String) {
  layer.imports
}

/// The capability names a layer withholds, as declared.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.withheld(layer) == ["lsp.rename"]
/// ```
pub fn withheld(layer: Layer) -> List(String) {
  layer.withheld
}

/// The host module's name and generated artifact, for the plan an owner
/// sends an executor.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.plan_module(layer) == option.Some(#("aegis", generated))
/// ```
pub fn plan_module(layer: Layer) -> Option(#(String, codegen.Generated)) {
  option.map(layer.module, fn(module) { #(module.name, module.generated) })
}

/// The vetting allowlist `policy` becomes under this layer: every `cap/*`
/// module the layer's imports omit removed, and the host module and its
/// vocabulary added.
///
/// ## Examples
///
/// ```gleam
/// // vet_policy.contains(host_seam.narrow(layer, vet_policy.default()), "cap/fs")
/// //   == False
/// ```
///
pub fn narrow(
  layer: Layer,
  policy: vet_policy.VetPolicy,
) -> vet_policy.VetPolicy {
  let admitted = set.from_list(layer.imports)
  let kept =
    vet_policy.allowed_imports(policy)
    |> list.filter(fn(module) {
      !string.starts_with(module, "cap/") || set.contains(admitted, module)
    })
    |> vet_policy.new
  list.fold(allowed_imports(layer), kept, vet_policy.allow)
}

/// The modules this layer adds to an allowlist: the host module and the
/// vocabulary it returns, or nothing for a seam with no module.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.allowed_imports(layer) == ["cap/mcp", "cap/aegis"]
/// ```
pub fn allowed_imports(layer: Layer) -> List(String) {
  case layer.module {
    None -> []
    Some(module) -> [vocabulary_module, module.generated.module_name]
  }
}

/// The capability names a seam advertises under this layer: `caps` without
/// the withheld ones and without any whose module the layer's imports
/// exclude, plus the host module's own.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.serviced_caps(layer, ["lsp.hover", "lsp.rename"])
/// //   == ["lsp.hover", "host.aegis"]
/// ```
///
pub fn serviced_caps(layer: Layer, caps: List(String)) -> List(String) {
  let kept = list.filter(caps, fn(cap) { admits(layer, cap) })

  // The module's one capability is advertised beside the narrowed list.
  case layer.module {
    None -> kept
    Some(module) -> list.append(kept, [cap_prefix <> module.name])
  }
}

/// The host module's rendered surface, for the `code_mode` description.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.surfaces(layer) == ["### cap/aegis\n..."]
/// ```
pub fn surfaces(layer: Layer) -> List(String) {
  case layer.module {
    None -> []
    Some(module) -> [module.generated.surface]
  }
}

/// The host module as the hermetic build takes it, `#(module name, source)`.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.generated(layer) == [#("cap/aegis", source)]
/// ```
pub fn generated(layer: Layer) -> List(#(String, String)) {
  case layer.module {
    None -> []
    Some(module) -> [
      #(module.generated.module_name, module.generated.source),
    ]
  }
}

/// Whether a session's owner may answer an owner-bound capability under this
/// layer, as a denial when it may not.
///
/// The owner cannot see the program, so it judges the call by the module the
/// capability belongs to: `strand.*` needs `cap/strand`, `host.aegis` needs
/// `cap/aegis` and so on, and a withheld name is refused whatever its module.
/// This is what holds a seam against an executor that ignores it.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.owner_admits(layer, "strand.spawn")
/// //   == Error(CapDenial("unsupported_cap", "..."))
/// ```
///
pub fn owner_admits(layer: Layer, cap: String) -> Result(Nil, CapDenial) {
  use <- bool.guard(when: admits(layer, cap), return: Ok(Nil))
  Error(CapDenial(
    code: withheld_code,
    message: "`"
      <> cap
      <> "` is not part of this session's code-mode seam, which its host chose",
  ))
}

/// The capability router arm for one execution: withheld names refused, the
/// host module's calls answered from its tools when this VM holds them, and
/// everything else handed to `inner`.
///
/// `holds` is the strand's tool-list check, or `None` on a host with no
/// messaging plane, which asks no tool question for any capability. `ctx` is
/// the tool context a function's tool runs under; `strand` and
/// `source_index` are the dispatching call's.
///
/// ## Examples
///
/// ```gleam
/// // host_seam.routing(layer, holds, ctx, strand: "main", source_index: 0, over: inner)
/// ```
///
pub fn routing(
  layer: Layer,
  holds holds: Option(fn(Caller, String) -> Result(Nil, Refusal)),
  ctx ctx: tool.Ctx,
  strand strand: String,
  source_index source_index: Int,
  over inner: CapRouter,
) -> CapRouter {
  fn(request: CapRequest) {
    use <- bool.lazy_guard(
      when: list.contains(layer.withheld, request.cap),
      return: fn() { Error(withheld_denial(request.cap)) },
    )

    // A `host.` name is this layer's to answer or refuse; nothing beneath it
    // knows the family.
    case string.starts_with(request.cap, cap_prefix) {
      False -> inner(request)
      True ->
        host_plan(layer, request, Program(holds:, ctx:, strand:, source_index:))
    }
  }
}

/// What one host call runs under, gathered so the planning helpers take one
/// value rather than four.
type Program {
  Program(
    holds: Option(fn(Caller, String) -> Result(Nil, Refusal)),
    ctx: tool.Ctx,
    strand: String,
    source_index: Int,
  )
}

// --- building --------------------------------------------------------------

/// Refuses an import that is neither a shipped `cap/*` module nor an MCP
/// façade, so a misspelt module is a refusal at assembly rather than a module
/// silently left out of every program.
fn known_import(module: String) -> Result(Nil, String) {
  let shipped =
    list.append(
      vet_policy.program_cap_modules(),
      vet_policy.harness_only_cap_modules(),
    )
  use <- bool.guard(
    when: list.contains(shipped, module)
      || string.starts_with(module, "cap/mcp/"),
    return: Ok(Nil),
  )
  Error(
    "the host's code-mode seam names `"
    <> module
    <> "`, which is not a capability module this Loom ships",
  )
}

/// Generates a host module after checking its name and its tools.
fn generate(module: HostModule) -> Result(Generated, String) {
  use Nil <- result.try(module_name(module.name))
  let names = list.map(module.functions, fn(function) { function.tool.name })
  use <- bool.lazy_guard(
    when: list.length(list.unique(names)) != list.length(names),
    return: fn() {
      Error("the host module " <> module.name <> " offers one tool twice")
    },
  )
  use descriptors <- result.try(list.try_map(module.functions, descriptor))
  use generated <- result.try(
    codegen.generate_host(module.name, descriptors, mcp_wiring.sha256_hex)
    |> result.map_error(codegen.describe),
  )
  Ok(Generated(
    name: module.name,
    generated:,
    answer: Here(functions: module.functions),
  ))
}

/// Checks a host module's name: a lower-case identifier the generator keeps
/// as it is, and not the name of a module Loom ships under `cap/`.
fn module_name(name: String) -> Result(Nil, String) {
  let module = "cap/" <> name
  let reserved =
    list.flatten([
      vet_policy.program_cap_modules(),
      vet_policy.harness_only_cap_modules(),
      ["cap/internal", "cap/mcp"],
    ])

  // The generator mangles a name it must change, so an unchanged name is a
  // legal identifier the module path can be built from.
  case
    vet_policy.is_legal_module_name(module)
    && mcp_name.mangle(name, mcp_wiring.sha256_hex) == name
    && !string.contains(name, "/"),
    list.contains(reserved, module)
  {
    True, False -> Ok(Nil)
    True, True ->
      Error("the host module name " <> name <> " is a module Loom ships")
    False, _ ->
      Error(
        "the host module name "
        <> string.inspect(name)
        <> " is not a lower-case Gleam identifier",
      )
  }
}

/// The tool descriptor the generator reads for one function: the tool's name,
/// description and argument schema, and the declared output.
fn descriptor(
  function: HostFunction,
) -> Result(mcp_protocol.ToolDescriptor, String) {
  use input <- result.try(to_mcp_json(function.tool.schema))
  use output <- result.map(output_schema(function.output))
  mcp_protocol.ToolDescriptor(
    name: function.tool.name,
    title: None,
    description: Some(function.tool.description),
    input_schema: input,
    output_schema: output,
  )
}

/// A function's declared output in the MCP library's JSON, when it has one.
fn output_schema(
  output: Option(JsonValue),
) -> Result(Option(mcp_json.JsonValue), String) {
  case output {
    None -> Ok(None)
    Some(schema) -> result.map(to_mcp_json(schema), Some)
  }
}

/// Loom's JSON as the MCP library's, by its text. The two types are the same
/// grammar, and a schema is read once at assembly.
fn to_mcp_json(value: JsonValue) -> Result(mcp_json.JsonValue, String) {
  mcp_json.parse(json.to_string(value))
  |> result.replace_error(
    "a host tool's schema is not JSON the generator reads",
  )
}

// --- admitting -------------------------------------------------------------

/// Whether a capability survives this layer: not withheld, and, for a family
/// whose module a program imports, that module admitted. A name of no such
/// family (an extension's `ext.*`) is not code mode's to judge.
fn admits(layer: Layer, cap: String) -> Bool {
  use <- bool.guard(when: list.contains(layer.withheld, cap), return: False)

  // The module is admitted when the host imports it, or when it is the host
  // module itself.
  case module_of(cap) {
    None -> True
    Some(module) ->
      list.contains(layer.imports, module)
      || list.contains(allowed_imports(layer), module)
  }
}

/// The module a program imports to make a call under `cap`, for the families
/// a code-mode program reaches. `lsp.snapshot` is `cap/lsp_sql`'s, the rest of
/// `lsp.*` is `cap/lsp`'s, `mcp.<server>` is the server's façade and
/// `host.<name>` is `cap/<name>`.
fn module_of(cap: String) -> Option(String) {
  case string.split_once(cap, ".") {
    Ok(#("mcp", server)) ->
      Some("cap/mcp/" <> mcp_name.mangle(server, mcp_wiring.sha256_hex))
    Ok(#("host", name)) -> Some("cap/" <> name)
    Ok(#("lsp", "snapshot")) -> Some("cap/lsp_sql")
    Ok(#(family, _)) -> family_module(family)
    Error(Nil) -> None
  }
}

/// The module behind one of the fixed families, or `None` for a family that
/// is not a code-mode module's.
fn family_module(family: String) -> Option(String) {
  let module = "cap/" <> family

  // The shipped lists are the one source of what a program may import.
  case
    list.contains(vet_policy.program_cap_modules(), module)
    || list.contains(vet_policy.harness_only_cap_modules(), module)
  {
    True -> Some(module)
    False -> None
  }
}

/// The refusal of a withheld capability.
fn withheld_denial(cap: String) -> CapDenial {
  CapDenial(
    code: withheld_code,
    message: "`" <> cap <> "` is withheld by this session's code-mode seam",
  )
}

// --- answering -------------------------------------------------------------

/// Plans one `host.<name>` call: the module must be this layer's and answered
/// here, and the arguments must name one of its tools. The tool-list check and
/// the run happen in the served worker, because `holds` reads durable state.
fn host_plan(
  layer: Layer,
  request: CapRequest,
  program: Program,
) -> Result(CapPlan, CapDenial) {
  let name = string.drop_start(request.cap, string.length(cap_prefix))
  use module <- result.try(this_module(layer, name, request.cap))
  use functions <- result.try(answered_here(module, request.cap))
  use tool_name <- result.try(string_field(request.args, "tool"))
  use function <- result.try(
    list.find(functions, fn(function) { function.tool.name == tool_name })
    |> result.map_error(fn(_nil) {
      CapDenial(
        code: mcp_wiring.invalid_argument_code,
        message: "the host module " <> name <> " has no function " <> tool_name,
      )
    }),
  )
  use arguments <- result.map(arguments_of(request.args))
  satellite.ServedHere(fn() { answer(function, arguments, request, program) })
}

/// The layer's module when `name` is it.
fn this_module(
  layer: Layer,
  name: String,
  cap: String,
) -> Result(Generated, CapDenial) {
  case layer.module {
    Some(module) if module.name == name -> Ok(module)
    Some(_) | None ->
      Error(CapDenial(
        code: withheld_code,
        message: "`" <> cap <> "` is not a module this session's host offers",
      ))
  }
}

/// The module's tools, when this VM holds them.
fn answered_here(
  module: Generated,
  cap: String,
) -> Result(List(HostFunction), CapDenial) {
  case module.answer {
    Here(functions:) -> Ok(functions)
    Elsewhere ->
      Error(CapDenial(
        code: withheld_code,
        message: "`" <> cap <> "` is answered by the session's owner",
      ))
  }
}

/// Runs one function: the strand must hold its tool, and then the tool's own
/// `run` is the answer, rendered in the envelope `cap/internal/mcp` reads.
fn answer(
  function: HostFunction,
  arguments: JsonValue,
  request: CapRequest,
  program: Program,
) -> CapOutcome {
  let caller =
    agent.Caller(
      strand: program.strand,
      operation: identity.op_id(request.identity),
      step_id: identity.step_id(request.identity),
      source_index: program.source_index,
      minter: agent.Program(ordinal: request.ordinal),
    )

  // A host with no messaging plane asks no tool question, as for every other
  // capability; one with a plane asks for the function's own tool.
  let held = case program.holds {
    None -> Ok(Nil)
    Some(holds) ->
      tool_gate.holding(holds, caller, request.cap, function.tool.name)
  }

  // A strand that does not hold the tool is refused before the tool runs, in
  // the words `tool_gate` uses for every other capability.
  case held {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(Nil) -> rendered(function, function.tool.run(program.ctx, arguments))
  }
}

/// A tool's outcome as an MCP-shaped result: its text blocks, whether it
/// failed, and its details as the structured value when the function declared
/// an output and the tool succeeded. An image block travels as its kind alone,
/// as an MCP server's does, so a program does not receive the image.
fn rendered(function: HostFunction, outcome: tool.ToolOutcome) -> CapOutcome {
  // Only a declared output on a success is decoded by the program, so only
  // then do the details travel as the structured value.
  let structured = case function.output, outcome.is_error, outcome.details {
    Some(_), False, Some(details) -> to_mcp_json(details) |> option.from_result
    Some(_), _, _ | None, _, _ -> None
  }

  mcp_wiring.tool_result(mcp_protocol.CallToolResult(
    content: list.map(outcome.content, block),
    is_error: outcome.is_error,
    structured_content: structured,
  ))
}

/// One content block of a tool's outcome. An image travels as its kind, as
/// an MCP server's does.
fn block(part: message.ToolResultBlock) -> mcp_protocol.ContentBlock {
  case part {
    message.ToolResultText(text:, ..) -> mcp_protocol.Text(text:)
    message.ToolResultImage(..) ->
      mcp_protocol.Other(kind: "image", raw: mcp_json.Object([]))
  }
}

/// A string field of the call's arguments.
fn string_field(args: MsgPackValue, key: String) -> Result(String, CapDenial) {
  case field(args, key) {
    Some(msgpack.StringValue(text)) -> Ok(text)
    Some(_) | None ->
      Error(CapDenial(
        code: mcp_wiring.invalid_argument_code,
        message: "a host call needs a string `" <> key <> "`",
      ))
  }
}

/// The function's arguments as the JSON its tool decodes.
fn arguments_of(args: MsgPackValue) -> Result(JsonValue, CapDenial) {
  let refused = fn(reason) {
    CapDenial(code: mcp_wiring.invalid_argument_code, message: reason)
  }

  // The generated module always sends the field; a call without it was not
  // made by one.
  use value <- result.try(case field(args, "arguments") {
    Some(value) -> Ok(value)
    None -> Error(refused("a host call needs its `arguments`"))
  })

  use converted <- result.try(
    interchange.to_json(value)
    |> result.map_error(fn(fault) {
      refused(
        "the arguments do not cross to JSON: " <> interchange.describe(fault),
      )
    }),
  )
  json.parse(mcp_json.to_string(converted))
  |> result.map_error(fn(_report) { refused("the arguments are not JSON") })
}

/// One field of a msgpack map.
fn field(args: MsgPackValue, key: String) -> Option(MsgPackValue) {
  case args {
    msgpack.MapValue(entries:) ->
      list.find(entries, fn(entry) { entry.0 == msgpack.StringValue(key) })
      |> result.map(fn(entry) { entry.1 })
      |> option.from_result
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> None
  }
}
