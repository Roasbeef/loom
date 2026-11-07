//// A host seam shaped like aegis's (protocol-change/111), for the tests.
////
//// The host's module is `cap/aegis`, with two of the host's own tools:
//// `file_finding`, which returns a typed result and refuses at the validation
//// stage, and `read_notes`, which returns plain text. The seam admits
//// `cap/search`, `cap/lsp`, `cap/task`, `cap/kv` and `cap/report`, withholds
//// `lsp.rename`, and so refuses every other module a program could import.

import broker/policy
import client/host_seam
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import tools/tool

/// The modules aegis's seam admits.
pub const imports = ["cap/search", "cap/lsp", "cap/task", "cap/kv", "cap/report"]

/// The sentence `file_finding` refuses with at the validation stage. A direct
/// call and a program both read it.
pub const refusal =
  "Refused: file_finding is not offered at the validation stage"

/// aegis's seam, with its module.
pub fn seam() -> host_seam.HostSeam {
  host_seam.HostSeam(
    imports:,
    withheld: ["lsp.rename"],
    module: Some(
      host_seam.HostModule(name: "aegis", functions: [
        host_seam.HostFunction(tool: file_finding(), output: Some(finding_id())),
        host_seam.HostFunction(tool: read_notes(), output: None),
      ]),
    ),
  )
}

/// The seam, built.
pub fn layer() -> host_seam.Layer {
  let assert Ok(layer) = host_seam.build(seam()) as "aegis's seam builds"
  layer
}

/// Files a finding: the title comes back with an id, except at the
/// validation stage, where the host refuses it.
pub fn file_finding() -> tool.Tool {
  tool.Tool(
    name: "file_finding",
    description: "File a finding for this job.",
    prompt_snippet: None,
    schema: json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #("title", json.Object([#("type", json.String("string"))])),
          #("stage", json.Object([#("type", json.String("string"))])),
        ]),
      ),
      #("required", json.Array([json.String("title"), json.String("stage")])),
    ]),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: fn(workspace) { policy.workspace_default(workspace) },
    run: fn(_ctx, arguments) { filed(arguments) },
  )
}

/// The result schema of `file_finding`.
pub fn finding_id() -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object([#("id", json.Object([#("type", json.String("integer"))]))]),
    ),
    #("required", json.Array([json.String("id")])),
  ])
}

/// Reads the job's notes, as plain text.
pub fn read_notes() -> tool.Tool {
  tool.Tool(
    ..file_finding(),
    name: "read_notes",
    description: "Read the job's notes.",
    schema: json.Object([
      #("type", json.String("object")),
      #("properties", json.Object([])),
    ]),
    run: fn(_ctx, _arguments) { tool.success("no notes yet") },
  )
}

fn filed(arguments: JsonValue) -> tool.ToolOutcome {
  case text_of(arguments, "title"), text_of(arguments, "stage") {
    Ok(_title), Ok("validation") -> tool.failure(refusal)
    Ok(title), Ok(_stage) ->
      tool.success("filed " <> title)
      |> tool.with_details(json.Object([#("id", json.Int(7))]))
    Error(Nil), _ | _, Error(Nil) ->
      tool.failure("Invalid arguments: file_finding needs a title and a stage")
  }
}

fn text_of(arguments: JsonValue, key: String) -> Result(String, Nil) {
  case arguments {
    json.Object(fields) ->
      case list.key_find(fields, key) {
        Ok(json.String(text)) -> Ok(text)
        _other -> Error(Nil)
      }
    _other -> Error(Nil)
  }
}
