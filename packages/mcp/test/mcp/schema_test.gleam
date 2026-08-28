import core/json.{type JsonValue}
import gleam/int
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

// --- hostile size and duplicate declarations --------------------------------

// The regression trip-wire for the quadratic `plan`. Before the fix,
// `required` membership was a scan of the kept list and each required
// name was a `list.key_find` over the `properties` pairs — two nested
// walks of the same attacker-controlled list. The size is chosen against
// the per-test budget rather than for roundness — 50s, eunit's 5s default
// times gleeunit's `scale_timeouts` of 10. Measured on this tree: keyed,
// `plan` over 100,000 names costs 0.37s; scanned, it costs 4.3s at 20,000
// and 20.7s at 40,000 (quadratic) and at 100,000 it does not finish, so
// the reverted shape ends this test as a eunit timeout rather than as a
// suite that is merely seconds slower. Built programmatically — a parsed
// string of this size would measure the parser instead.
const hostile_param_count = 100_000

pub fn a_huge_required_list_plans_in_linear_time_test() {
  // ["p0", … , "p99999"], counted down so every step is one prepend.
  let names =
    int.range(from: hostile_param_count - 1, to: -1, with: [], run: fn(acc, i) {
      ["p" <> int.to_string(i), ..acc]
    })
  let properties = list.map(names, fn(name) { #(name, typed("string")) })
  let assert schema.Typed(params:, optionals: []) =
    schema.plan(object_schema(properties, names))
    as "a large well-formed object schema should plan as typed"
  assert list.length(params) == hostile_param_count
  // Every one is Tier 1, and the `required` order is kept end to end.
  assert list.all(params, fn(param) {
    param.kind == schema.Simple(scalar: schema.ScalarString)
  })
  assert list.first(params) == Ok(simple("p0", schema.ScalarString))
  assert list.last(params) == Ok(simple("p99999", schema.ScalarString))
}

// `json.Object` keeps a duplicate key as repeated pairs, and the plan
// answers with the *first* declaration in both dimensions: the first
// `required` occurrence fixes the parameter's position, the first
// `properties` pair fixes its type. A dict built by blind insert would
// have kept the `integer`.
pub fn the_first_declaration_of_a_duplicated_name_wins_test() {
  let input_schema =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #("a", typed("string")),
          #("a", typed("integer")),
          #("b", typed("integer")),
        ]),
      ),
      #(
        "required",
        json.Array([json.String("a"), json.String("b"), json.String("a")]),
      ),
    ])
  assert schema.plan(input_schema)
    == schema.Typed(
      params: [
        simple("a", schema.ScalarString),
        simple("b", schema.ScalarInt),
      ],
      optionals: [],
    )
}

// The other dimension of the same duplication, pinned as it stands: an
// optional key declared twice surfaces once per pair. Optionals are
// documented pass-through keys rather than arguments, so a repeat costs
// a duplicated doc line and nothing else.
pub fn a_duplicated_optional_key_surfaces_per_pair_test() {
  let input_schema =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([
          #("x", described("string", "first")),
          #("x", described("integer", "second")),
        ]),
      ),
    ])
  assert schema.plan(input_schema)
    == schema.Typed(params: [], optionals: [
      schema.Optional(original: "x", note: Some("first")),
      schema.Optional(original: "x", note: Some("second")),
    ])
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
