//// Sources the scripted model authors through ordinary filesystem tool calls.
//// Version markers are checked by candidate-owned tests and independently by
//// the operator fixture after actual invocation. The tests also cross cap/proc,
//// so a passing pure string comparison cannot replace a working jailed seam.

import core/json
import gleam/int

/// Produces the complete bounded extension and its separately admitted tests.
///
/// ## Examples
///
/// `extension(1)` returns source strings, never a preinstalled executable.
pub fn extension(version: Int) -> List(#(String, String)) {
  let marker = "version-" <> int.to_string(version)
  [
    #("extension.toml", extension_manifest()),
    #("gleam.toml", project),
    #("schema/echo.json", json.to_string(schema())),
    #("src/evolution_echo.gleam", implementation(marker)),
    #("test/evolution_check.gleam", check(marker)),
  ]
}

/// The exact contract the operator and scripted model inspect.
///
/// ## Examples
///
/// `schema()` requires one fresh string argument.
pub fn schema() -> json.JsonValue {
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object([
        #("say", json.Object([#("type", json.String("string"))])),
      ]),
    ),
    #("required", json.Array([json.String("say")])),
    #("additionalProperties", json.Bool(False)),
  ])
}

fn extension_manifest() -> String {
  "[extension]\nname = \"evolution_echo\"\nversion = \"0.1.0\"\n"
  <> "description = \"A governed live echo fixture.\"\nlicense = \"MIT\"\n"
  <> "tier = \"jailed\"\n\n[[tool]]\nname = \"evolution_echo\"\n"
  <> "description = \"Echo fresh inputs with this version's marker.\"\n"
  <> "prompt_snippet = \"Use evolution_echo to echo a fresh value.\"\n"
  <> "parameters = \"schema/echo.json\"\nentry = \"evolution_echo\"\n"
  <> "timeout_ms = 20000\n"
}

const project =
  "name = \"evolution_echo\"\nversion = \"0.1.0\"\ngleam = \">= 1.18.0\"\n\n"
  <> "[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
  <> "ext = { path = \"../ext\" }\n"

fn implementation(marker: String) -> String {
  "//// Immutable echo implementation used by the acceptance fixture.\n"
  <> "import ext\nimport gleam/dynamic\nimport gleam/dynamic/decode\n"
  <> "import gleam/result\n\n"
  <> "/// Composes the implementation marker with a fresh input.\n"
  <> "pub fn render(say: String) -> String {\n  \""
  <> marker
  <> ":\" <> say\n}\n\n"
  <> "/// Decodes arguments before rendering the retained version.\n"
  <> "pub fn run(arguments: dynamic.Dynamic, _ctx: ext.Ctx) -> Result(ext.Outcome, ext.Refusal) {\n"
  <> "  let decoder = {\n    use say <- decode.field(\"say\", decode.string)\n"
  <> "    decode.success(say)\n  }\n\n"
  <> "  use say <- result.try(ext.decode_args(arguments, decoder))\n"
  <> "  Ok(ext.text(render(say)))\n}\n"
}

fn check(marker: String) -> String {
  "//// Candidate-owned checks retained inside the content address.\n"
  <> "import cap/proc\nimport cap/report\nimport evolution_echo\n\n"
  <> "/// Checks implementation and a real brokered native process.\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case evolution_echo.render(\"fresh\") == \""
  <> marker
  <> ":fresh\" {\n"
  <> "    False -> report.failure(\"wrong immutable implementation\")\n"
  <> "    True -> {\n      case proc.run(proc.command([\"/bin/echo\", \"author-test\"])) {\n"
  <> "        Ok(result) if result.exit_code == 0 -> report.text(\""
  <> marker
  <> " tested\")\n"
  <> "        Ok(_) -> report.failure(\"native process failed\")\n"
  <> "        Error(_) -> report.failure(\"native process unavailable\")\n"
  <> "      }\n    }\n  }\n}\n"
}
