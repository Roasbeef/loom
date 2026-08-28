import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import mcp/schema

// --- fixtures ------------------------------------------------------------

fn object_schema(
  properties: List(#(String, JsonValue)),
  required: List(String),
) -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #("properties", json.Object(properties)),
    #("required", json.Array(list.map(required, json.String))),
  ])
}

fn typed(kind: String) -> JsonValue {
  json.Object([#("type", json.String(kind))])
}

fn described(kind: String, note: String) -> JsonValue {
  json.Object([
    #("type", json.String(kind)),
    #("description", json.String(note)),
  ])
}

fn array_of(items: JsonValue) -> JsonValue {
  json.Object([#("type", json.String("array")), #("items", items)])
}

fn simple(name: String, scalar: schema.Scalar) -> schema.Param {
  schema.Param(
    original: name,
    kind: schema.Simple(scalar:),
    note: None,
    one_of: [],
  )
}

// --- tier 1: every shape in the typed subset -----------------------------

pub fn scalar_shapes_plan_typed_test() {
  let plan =
    schema.plan(
      object_schema(
        [
          #("a", typed("string")),
          #("b", typed("integer")),
          #("c", typed("number")),
          #("d", typed("boolean")),
        ],
        ["a", "b", "c", "d"],
      ),
    )
  assert plan
    == schema.Typed(
      params: [
        simple("a", schema.ScalarString),
        simple("b", schema.ScalarInt),
        simple("c", schema.ScalarFloat),
        simple("d", schema.ScalarBool),
      ],
      optionals: [],
    )
}

pub fn scalar_array_shapes_plan_typed_test() {
  let plan =
    schema.plan(
      object_schema(
        [
          #("a", array_of(typed("string"))),
          #("b", array_of(typed("integer"))),
          #("c", array_of(typed("number"))),
          #("d", array_of(typed("boolean"))),
        ],
        ["a", "b", "c", "d"],
      ),
    )
  let listed = fn(name, scalar) {
    schema.Param(
      original: name,
      kind: schema.ListOf(scalar:),
      note: None,
      one_of: [],
    )
  }
  assert plan
    == schema.Typed(
      params: [
        listed("a", schema.ScalarString),
        listed("b", schema.ScalarInt),
        listed("c", schema.ScalarFloat),
        listed("d", schema.ScalarBool),
      ],
      optionals: [],
    )
}

// Annotation keys never disqualify a parameter from the typed subset.
pub fn annotations_do_not_disqualify_test() {
  let annotated =
    json.Object([
      #("type", json.String("string")),
      #("description", json.String("a name")),
      #("format", json.String("email")),
      #("default", json.String("x")),
      #("minLength", json.Int(1)),
    ])
  assert schema.plan(object_schema([#("a", annotated)], ["a"]))
    == schema.Typed(
      params: [
        schema.Param(
          original: "a",
          kind: schema.Simple(scalar: schema.ScalarString),
          note: Some("a name"),
          one_of: [],
        ),
      ],
      optionals: [],
    )
}

// An enum stays a string; the values ride along for the doc prose.
pub fn string_enum_stays_string_test() {
  let state =
    json.Object([
      #("type", json.String("string")),
      #(
        "enum",
        json.Array([json.String("open"), json.String("closed"), json.Int(3)]),
      ),
    ])
  assert schema.plan(object_schema([#("state", state)], ["state"]))
    == schema.Typed(
      params: [
        schema.Param(
          original: "state",
          kind: schema.Simple(scalar: schema.ScalarString),
          note: None,
          one_of: ["open", "closed"],
        ),
      ],
      optionals: [],
    )
}

// --- tier 2: per-parameter fallback ----------------------------------------

fn required_kind(input_schema: JsonValue) -> schema.ParamType {
  let assert schema.Typed(params: [param], optionals: []) =
    schema.plan(input_schema)
  param.kind
}

fn structured(input_schema: JsonValue) -> Bool {
  case required_kind(input_schema) {
    schema.Structured(..) -> True
    schema.Simple(..) -> False
    schema.ListOf(..) -> False
  }
}

pub fn nested_object_parameter_is_structured_test() {
  assert structured(object_schema([#("a", typed("object"))], ["a"]))
}

pub fn array_of_objects_is_structured_test() {
  assert structured(object_schema([#("a", array_of(typed("object")))], ["a"]))
}

pub fn nested_array_items_are_structured_test() {
  assert structured(
    object_schema([#("a", array_of(array_of(typed("string"))))], ["a"]),
  )
}

pub fn any_of_is_structured_test() {
  let any_of = json.Object([#("anyOf", json.Array([typed("string")]))])
  assert structured(object_schema([#("a", any_of)], ["a"]))
}

pub fn ref_is_structured_test() {
  let ref = json.Object([#("$ref", json.String("#/definitions/thing"))])
  assert structured(object_schema([#("a", ref)], ["a"]))
}

pub fn type_array_is_structured_test() {
  let two_types =
    json.Object([
      #("type", json.Array([json.String("string"), json.String("null")])),
    ])
  assert structured(object_schema([#("a", two_types)], ["a"]))
}

pub fn boolean_schema_is_structured_test() {
  assert structured(object_schema([#("a", json.Bool(True))], ["a"]))
}

pub fn missing_items_are_structured_test() {
  assert structured(object_schema([#("a", typed("array"))], ["a"]))
}

// A `required` name with no `properties` entry still becomes a required
// argument — a structured one — because dropping a parameter is the one
// forbidden move.
pub fn required_name_absent_from_properties_is_kept_test() {
  assert schema.plan(object_schema([], ["ghost"]))
    == schema.Typed(
      params: [
        schema.Param(
          original: "ghost",
          kind: schema.Structured(
            reason: "required but not declared in properties",
          ),
          note: None,
          one_of: [],
        ),
      ],
      optionals: [],
    )
}

pub fn empty_param_name_is_kept_test() {
  let assert schema.Typed(params: [param], optionals: []) =
    schema.plan(object_schema([#("", typed("string"))], [""]))
  assert param.original == ""
}

// --- tier 3: whole-value fallback ------------------------------------------

pub fn null_input_schema_is_whole_value_test() {
  assert schema.plan(json.Null)
    == schema.WholeValue(reason: "inputSchema is not an object")
}

pub fn non_object_type_is_whole_value_test() {
  assert schema.plan(typed("string"))
    == schema.WholeValue(reason: "inputSchema type is not \"object\"")
}

pub fn missing_top_level_type_is_whole_value_test() {
  assert schema.plan(json.Object([#("properties", json.Object([]))]))
    == schema.WholeValue(reason: "inputSchema declares no type")
}

pub fn non_object_properties_is_whole_value_test() {
  let bad =
    json.Object([
      #("type", json.String("object")),
      #("properties", json.Array([])),
    ])
  assert schema.plan(bad)
    == schema.WholeValue(reason: "properties is not an object")
}

pub fn non_array_required_is_whole_value_test() {
  let bad =
    json.Object([
      #("type", json.String("object")),
      #("properties", json.Object([])),
      #("required", json.String("a")),
    ])
  assert schema.plan(bad)
    == schema.WholeValue(reason: "required is not an array")
}

pub fn non_string_required_entry_is_whole_value_test() {
  let bad =
    json.Object([
      #("type", json.String("object")),
      #("properties", json.Object([])),
      #("required", json.Array([json.String("a"), json.Int(2)])),
    ])
  assert schema.plan(bad)
    == schema.WholeValue(reason: "required holds a non-string entry")
}

// --- optionals ---------------------------------------------------------------

// `properties` present, `required` missing: every parameter is optional,
// so the plan has no typed arguments at all.
pub fn missing_required_means_all_optional_test() {
  let no_required =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #("a", described("string", "first")),
          #("b", typed("integer")),
        ]),
      ),
    ])
  assert schema.plan(no_required)
    == schema.Typed(params: [], optionals: [
      schema.Optional(original: "a", note: Some("first")),
      schema.Optional(original: "b", note: None),
    ])
}

pub fn missing_properties_plan_is_empty_test() {
  assert schema.plan(json.Object([#("type", json.String("object"))]))
    == schema.Typed(params: [], optionals: [])
}

pub fn optionals_keep_properties_order_test() {
  let plan =
    schema.plan(
      object_schema(
        [
          #("z", typed("string")),
          #("req", typed("string")),
          #("a", typed("string")),
        ],
        ["req"],
      ),
    )
  let assert schema.Typed(params: [_], optionals:) = plan
  assert list.map(optionals, fn(optional) { optional.original }) == ["z", "a"]
}

// A duplicated `required` name is one wire parameter, not two arguments.
pub fn duplicate_required_names_dedupe_test() {
  let plan = schema.plan(object_schema([#("a", typed("string"))], ["a", "a"]))
  assert plan
    == schema.Typed(params: [simple("a", schema.ScalarString)], optionals: [])
}

// Required parameters keep the `required` array's order, not the
// `properties` order.
pub fn required_order_wins_test() {
  let plan =
    schema.plan(
      object_schema([#("b", typed("string")), #("a", typed("string"))], [
        "a",
        "b",
      ]),
    )
  let assert schema.Typed(params:, optionals: []) = plan
  assert list.map(params, fn(param) { param.original }) == ["a", "b"]
}
