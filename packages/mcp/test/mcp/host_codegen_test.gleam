//// A host's own capability module through the MCP generator
//// (protocol-change/111): the same rendering as a server's façade, under
//// `cap/<name>` and the `host.` capability family.

import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/json
import gleam_mcp/protocol
import mcp/codegen

fn stub_digest(text: String) -> String {
  bit_array.base16_encode(bit_array.from_string(text))
  |> string.lowercase
}

fn tools() -> List(protocol.ToolDescriptor) {
  [
    protocol.ToolDescriptor(
      name: "file_finding",
      title: None,
      description: Some("File a finding."),
      input_schema: json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #("title", json.Object([#("type", json.String("string"))])),
          ]),
        ),
        #("required", json.Array([json.String("title")])),
      ]),
      output_schema: Some(
        json.Object([
          #("type", json.String("object")),
          #(
            "properties",
            json.Object([
              #("id", json.Object([#("type", json.String("integer"))])),
            ]),
          ),
          #("required", json.Array([json.String("id")])),
        ]),
      ),
    ),
    protocol.ToolDescriptor(
      name: "read_notes",
      title: None,
      description: Some("Read notes."),
      input_schema: json.Object([#("type", json.String("object"))]),
      output_schema: None,
    ),
  ]
}

pub fn a_host_module_is_named_under_cap_and_calls_the_host_family_test() {
  let assert Ok(generated) =
    codegen.generate_host("aegis", tools(), stub_digest)
    as "the host module generates"
  assert generated.module_name == "cap/aegis"

  // Every body crosses as `host.aegis`, typed where an output is declared;
  // none can reach an MCP server.
  assert string.contains(generated.source, "internal.host_invoke_typed(")
  assert string.contains(generated.source, "internal.host_invoke(")
  assert !string.contains(generated.source, "internal.invoke(")
  assert !string.contains(generated.source, "internal.invoke_typed(")
  assert string.contains(generated.source, "\"aegis\"")
  assert string.starts_with(generated.surface, "### cap/aegis\n")
  assert string.contains(generated.surface, "host's own text")
  assert codegen.scan_for_at(generated.source) == Ok(Nil)
}

pub fn the_same_listing_as_a_server_is_unchanged_test() {
  // The host target is a second entry, not a change to the first.
  let assert Ok(generated) = codegen.generate("aegis", tools(), stub_digest)
    as "the server façade generates"
  assert generated.module_name == "cap/mcp/aegis"
  assert string.contains(generated.source, "internal.invoke_typed(")
  assert !string.contains(generated.source, "host_invoke")
}

pub fn a_host_description_cannot_plant_an_attribute_test() {
  // The host's text is sanitized as a server's is, and the backstop holds.
  let hostile =
    protocol.ToolDescriptor(
      name: "x",
      title: None,
      description: Some(
        "ok\n@external(erlang, \"os\", \"cmd\")\npub fn y() { 1 }",
      ),
      input_schema: json.Object([#("type", json.String("object"))]),
      output_schema: None,
    )
  let assert Ok(generated) =
    codegen.generate_host("aegis", [hostile], stub_digest)
    as "the hostile description is rendered inert"
  assert codegen.scan_for_at(generated.source) == Ok(Nil)
  assert !string.contains(generated.source, "\npub fn y()")
}
