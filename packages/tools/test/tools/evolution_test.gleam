//// Model-facing schemas must admit the arguments required by native evaluation.

import core/json
import gleam/list
import gleeunit/should
import tools/evolution
import tools/tool

pub fn prompt_evaluation_schema_admits_native_taskset_and_exact_limits_test() {
  let unused = fn(_, _) { tool.failure("schema test does not execute effects") }
  let registry =
    tool.registry(
      evolution.tools(evolution.Door(unused, unused, unused, unused, unused)),
    )
  let assert Ok(declared) = tool.lookup(registry, "evolution_test")
    as "the production lifecycle registry advertises its evaluation tool"
  let properties = object(field(declared.schema, "properties"))
  list.map(properties, fn(property) { property.0 })
  |> should.equal(["candidate_id", "taskset_id", "limits"])
  field(declared.schema, "required")
  |> should.equal(json.Array([json.String("candidate_id")]))
  field(declared.schema, "additionalProperties")
  |> should.equal(json.Bool(False))
  let limits = field(declared.schema, "properties") |> field("limits")
  let names = [
    "trials",
    "turns",
    "tokens",
    "dollars",
    "output_bytes",
    "wall_ms",
  ]
  list.map(object(field(limits, "properties")), fn(property) { property.0 })
  |> should.equal(names)
  field(limits, "required")
  |> should.equal(json.Array(list.map(names, json.String)))
  field(limits, "additionalProperties") |> should.equal(json.Bool(False))
  field(field(field(limits, "properties"), "dollars"), "type")
  |> should.equal(json.String("number"))
}

fn object(value: json.JsonValue) -> List(#(String, json.JsonValue)) {
  let assert json.Object(fields) = value as "the schema field is an object"
  fields
}

fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert Ok(found) = list.key_find(object(value), name)
    as "the native advertised schema contains the expected field"
  found
}
