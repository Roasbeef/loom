//// `mcp/schema` keeps untrusted wire schemas separate from generated code.
////
//// Reading path: check_budget first bounds all schema, annotation and literal
//// text; input_fields validates an object-shaped input and preserves required
//// wire names; shape and shape_at recursively build bounded structural Shapes.
//// shape_fields chooses combinators before primitive declarations, record_fields
//// preserves presence/default metadata, and union_shape admits only branches
//// whose shapes prove exclusivity. An unsupported field remains ValueFallback.
//// Nullable data and optional presence are independent, so explicit null cannot
//// silently become an absent property. Numeric ranges, formats and other scalar
//// annotations remain the remote server's responsibility.
////
//// The older plan/Plan/ParamType projection remains available for callers doing
//// scalar-tier accounting. The renderer consumes input_fields and Shape instead;
//// it does not inherit the legacy optional pass-through representation.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam_mcp/json.{type JsonValue}

/// The four scalar shapes the typed subset admits.
pub type Scalar {
  /// The string scalar; the richer plan handles enum literals separately.
  ScalarString

  /// `{"type": "integer"}`.
  ScalarInt

  /// `{"type": "number"}`.
  ScalarFloat

  /// `{"type": "boolean"}`.
  ScalarBool
}

/// How one required parameter travels.
pub type ParamType {
  /// Tier 1: one scalar, as its Gleam type.
  Simple(scalar: Scalar)

  /// Tier 1: an array of one scalar, as a Gleam `List`.
  ListOf(scalar: Scalar)

  /// Tier 2: anything else, as one structured `report.Value`. `reason`
  /// says what pushed it out of the typed subset, worded for a doc
  /// comment (and sanitized by the renderer, since it can embed the
  /// server's own text).
  Structured(reason: String)
}

/// One required parameter. `original` is the wire name, verbatim and
/// untrusted; `note` is the schema's `description`, verbatim and
/// untrusted; `one_of` holds the string members of an `enum`, if any,
/// for the doc prose.
pub type Param {
  Param(
    original: String,
    kind: ParamType,
    note: Option(String),
    one_of: List(String),
  )
}

/// One optional parameter: never an argument, only a documented key the
/// caller may pass through the façade's `options` list. Both fields are
/// the server's text, verbatim and untrusted.
pub type Optional {
  Optional(original: String, note: Option(String))
}

/// What a tool's input schema settles as. Total: there is no error case,
/// because Tier 3 *is* the failure mode, carried as data.
pub type Plan {
  /// The schema was a usable object schema: required parameters in
  /// `required`-array order (first occurrence wins on duplicates),
  /// optionals in `properties` order.
  Typed(params: List(Param), optionals: List(Optional))

  /// Tier 3: the top level could not be rendered as typed arguments;
  /// `reason` is worded for the generated doc comment.
  WholeValue(reason: String)
}

/// Interprets one tool's raw `inputSchema` into a plan. Total — hostile
/// or vacuous schemas settle as `WholeValue` or `Structured` parameters,
/// never a crash and never a dropped parameter.
///
/// A schema with `properties` but no `required` array plans as all
/// optional: no typed arguments, everything through `options`. A missing
/// `properties` object with a well-formed top level plans as no
/// parameters at all.
///
/// ## Examples
///
/// ```gleam
/// assert schema.plan(json.Null)
///   == schema.WholeValue(reason: "inputSchema is not an object")
/// ```
///
pub fn plan(input_schema: JsonValue) -> Plan {
  case top_level(input_schema) {
    Error(reason) -> WholeValue(reason:)
    Ok(#(properties, required)) -> {
      // A hostile schema can hold hundreds of thousands of names inside
      // one listing line, so both lookups are built once — membership
      // over `required`, first declaration over `properties` — and every
      // per-name step is a keyed lookup rather than a list scan. Scans
      // here made `plan` quadratic in attacker-controlled input, which
      // is CPU exhaustion in the harness during generation.
      let declared = first_declarations(properties)
      let required_names = set.from_list(required)
      Typed(
        params: list.map(required, required_param(_, declared)),
        optionals: optionals(properties, required_names),
      )
    }
  }
}

// --- the top level -----------------------------------------------------------

fn top_level(
  input_schema: JsonValue,
) -> Result(#(List(#(String, JsonValue)), List(String)), String) {
  use fields <- result.try(case input_schema {
    json.Object(fields) -> Ok(fields)
    _ -> Error("inputSchema is not an object")
  })
  use Nil <- result.try(case list.key_find(fields, "type") {
    Ok(json.String("object")) -> Ok(Nil)
    Ok(_) -> Error("inputSchema type is not \"object\"")
    Error(Nil) -> Error("inputSchema declares no type")
  })
  use properties <- result.try(case list.key_find(fields, "properties") {
    Error(Nil) -> Ok([])
    Ok(json.Object(properties)) -> Ok(properties)
    Ok(_) -> Error("properties is not an object")
  })
  use required <- result.try(required_names(fields))
  Ok(#(properties, required))
}

fn required_names(
  fields: List(#(String, JsonValue)),
) -> Result(List(String), String) {
  use entries <- result.try(case list.key_find(fields, "required") {
    Error(Nil) -> Ok([])
    Ok(json.Array(entries)) -> Ok(entries)
    Ok(_) -> Error("required is not an array")
  })
  use names <- result.try(
    list.try_map(entries, fn(entry) {
      case entry {
        json.String(name) -> Ok(name)
        _ -> Error("required holds a non-string entry")
      }
    }),
  )
  Ok(dedupe(names))
}

// A name `required` lists twice is one wire parameter; the first
// occurrence keeps its place and the rest are dropped rather than minting
// a duplicate argument. Membership is a set, not a scan of the kept list,
// so a million-name `required` costs n log n rather than n².
fn dedupe(names: List(String)) -> List(String) {
  let #(_seen, kept) =
    list.fold(names, #(set.new(), []), fn(state, name) {
      let #(seen, kept) = state
      case set.contains(seen, name) {
        True -> state
        False -> #(set.insert(seen, name), [name, ..kept])
      }
    })
  list.reverse(kept)
}

// `json.Object` keeps a duplicate key as repeated pairs, and the list
// scan this replaces answered with the *first* — a dict built by blind
// insert would keep the last, silently changing which declaration wins.
// The fold inserts only names not yet present, so first still wins.
fn first_declarations(
  properties: List(#(String, JsonValue)),
) -> Dict(String, JsonValue) {
  list.fold(properties, dict.new(), fn(declared, entry) {
    let #(name, value) = entry
    case dict.has_key(declared, name) {
      True -> declared
      False -> dict.insert(declared, name, value)
    }
  })
}

// --- required parameters -----------------------------------------------------

fn required_param(name: String, declared: Dict(String, JsonValue)) -> Param {
  case dict.get(declared, name) {
    // Tier 2 by decree: `required` names it, `properties` never declared
    // it, and dropping a parameter is the one thing this module must
    // never do.
    Error(Nil) ->
      structured_param(name, "required but not declared in properties")
    Ok(declared) -> interpret(name, declared)
  }
}

fn interpret(name: String, declared: JsonValue) -> Param {
  case declared {
    json.Object(fields) ->
      Param(
        original: name,
        kind: kind_of(fields),
        note: note_of(fields),
        one_of: enum_of(fields),
      )
    json.Bool(_) -> structured_param(name, "a boolean schema")
    _ -> structured_param(name, "the schema is not an object")
  }
}

fn structured_param(name: String, reason: String) -> Param {
  Param(original: name, kind: Structured(reason:), note: None, one_of: [])
}

fn kind_of(fields: List(#(String, JsonValue))) -> ParamType {
  case list.key_find(fields, "type") {
    Ok(json.String("string")) -> Simple(scalar: ScalarString)
    Ok(json.String("integer")) -> Simple(scalar: ScalarInt)
    Ok(json.String("number")) -> Simple(scalar: ScalarFloat)
    Ok(json.String("boolean")) -> Simple(scalar: ScalarBool)
    Ok(json.String("array")) -> items_of(fields)
    Ok(json.String(other)) ->
      Structured(reason: "type \"" <> other <> "\" is beyond the typed subset")
    Ok(_) -> Structured(reason: "type is not a single string")
    Error(Nil) -> Structured(reason: "the schema declares no type")
  }
}

fn items_of(fields: List(#(String, JsonValue))) -> ParamType {
  case list.key_find(fields, "items") {
    Error(Nil) -> Structured(reason: "array items are undeclared")
    Ok(json.Object(items)) -> scalar_items(items)
    Ok(_) -> Structured(reason: "array items are not an object schema")
  }
}

fn scalar_items(items: List(#(String, JsonValue))) -> ParamType {
  case list.key_find(items, "type") {
    Ok(json.String("string")) -> ListOf(scalar: ScalarString)
    Ok(json.String("integer")) -> ListOf(scalar: ScalarInt)
    Ok(json.String("number")) -> ListOf(scalar: ScalarFloat)
    Ok(json.String("boolean")) -> ListOf(scalar: ScalarBool)
    Ok(json.String(other)) ->
      Structured(
        reason: "array of \"" <> other <> "\" is beyond the typed subset",
      )
    Ok(_) -> Structured(reason: "array items type is not a single string")
    Error(Nil) -> Structured(reason: "array items declare no type")
  }
}

fn note_of(fields: List(#(String, JsonValue))) -> Option(String) {
  case list.key_find(fields, "description") {
    Ok(json.String(note)) -> Some(note)
    Ok(_) -> None
    Error(Nil) -> None
  }
}

// Only string members: enum values are rendered into doc prose, and a
// string is the one member kind prose can quote faithfully. A non-string
// member neither disqualifies the parameter nor appears in the prose.
fn enum_of(fields: List(#(String, JsonValue))) -> List(String) {
  case list.key_find(fields, "enum") {
    Ok(json.Array(members)) ->
      list.filter_map(members, fn(member) {
        case member {
          json.String(value) -> Ok(value)
          _ -> Error(Nil)
        }
      })
    Ok(_) -> []
    Error(Nil) -> []
  }
}

// --- optionals ---------------------------------------------------------------

fn optionals(
  properties: List(#(String, JsonValue)),
  required: Set(String),
) -> List(Optional) {
  list.filter_map(properties, fn(entry) {
    let #(name, declared) = entry
    case set.contains(required, name) {
      True -> Error(Nil)
      False -> Ok(Optional(original: name, note: declared_note(declared)))
    }
  })
}

fn declared_note(declared: JsonValue) -> Option(String) {
  case declared {
    json.Object(fields) -> note_of(fields)
    _ -> None
  }
}

/// Whether a record field must occur on the wire.
pub type Presence {
  /// Missing values fail decoding.
  Required

  /// Missing values are distinct from explicit nullable values.
  OptionalField
}

/// Additional properties follow the schema's explicit object policy.
pub type Openness {
  /// Unknown properties may be present in decoded records.
  Open

  /// Unknown properties fail decoding.
  Closed
}

/// A bounded structural plan. Unsupported constraints remain server-validated;
/// unsupported shapes retain their entire field as a value.
pub type Shape {
  /// A primitive scalar.
  Primitive(
    /// Scalar wire category.
    scalar: Scalar,
  )

  /// String literals become a closed constructor set.
  Enumeration(
    /// Distinct admitted string literals.
    values: List(String),
  )

  /// A recursively typed homogeneous list.
  Sequence(
    /// Shape of every list item.
    item: Shape,
  )

  /// Named properties have their own presence and nullable semantics.
  Record(
    /// Required-first named property plans.
    fields: List(Field),
    /// Whether unknown decoded properties are admitted.
    openness: Openness,
  )

  /// A homogeneous map keeps its dynamic wire keys.
  Mapping(
    /// Shape of every dynamically keyed value.
    item: Shape,
  )

  /// Explicit null is represented separately from absence.
  Nullable(
    /// Shape admitted beside explicit null.
    inner: Shape,
  )

  /// Exactly one branch must decode successfully.
  Alternatives(
    /// Structurally disjoint branch plans.
    branches: List(Shape),
  )

  /// An object whose internal shape is unspecified.
  RawObject

  /// An array whose item shape is unspecified.
  RawArray

  /// Only the JSON null value.
  NullValue

  /// A field outside the supported structural subset.
  ValueFallback(
    /// Why this field retains the unrestricted wire representation.
    reason: String,
  )
}

/// One field keeps the server's wire identity separate from its generated label.
pub type Field {
  Field(
    /// Original wire property name.
    original: String,
    /// Structural interpretation of this property's schema.
    shape: Shape,
    /// Required or optional wire presence.
    presence: Presence,
    /// Untrusted description, sanitized by the renderer.
    note: Option(String),
    /// Untrusted schema default, shown as prose; omission lets the server apply it.
    default: Option(JsonValue),
  )
}

/// Interprets a field or output schema into a recursive shape. Depth is bounded
/// even when callers bypass generation's aggregate node and byte budget.
///
/// ## Examples
///
/// ```gleam
/// assert schema.shape(json.Null) == schema.ValueFallback("schema is not an object")
/// ```
pub fn shape(value: JsonValue) -> Shape {
  shape_at(value, 0)
}

fn shape_at(value: JsonValue, depth: Int) -> Shape {
  case depth >= 12 {
    True -> ValueFallback("schema depth exceeds 12")
    False ->
      case value {
        json.Object(fields) -> shape_fields(fields, depth)
        _ -> ValueFallback("schema is not an object")
      }
  }
}

fn shape_fields(fields: List(#(String, JsonValue)), depth: Int) -> Shape {
  // References and mixed combinators are retained as values rather than
  // interpreted as a weaker primitive declaration beside them.
  case
    dict.has_key(dict.from_list(fields), "$ref")
    || dict.has_key(dict.from_list(fields), "allOf")
    || dict.has_key(dict.from_list(fields), "anyOf")
  {
    True -> ValueFallback("references or unsupported combinators")
    False ->
      case list.key_find(fields, "oneOf") {
        Ok(json.Array(branches)) if branches != [] ->
          case list.drop(branches, 32) != [] {
            True -> ValueFallback("oneOf exceeds 32 branches")
            False -> union_shape(list.map(branches, shape_at(_, depth + 1)))
          }
        Ok(_) -> ValueFallback("oneOf is not a nonempty array")
        Error(Nil) -> declared_shape(fields, depth)
      }
  }
}

fn declared_shape(fields: List(#(String, JsonValue)), depth: Int) -> Shape {
  case list.key_find(fields, "type") {
    Ok(json.String("string")) -> string_shape(fields)
    Ok(json.String("integer")) -> Primitive(ScalarInt)
    Ok(json.String("number")) -> Primitive(ScalarFloat)
    Ok(json.String("boolean")) -> Primitive(ScalarBool)
    Ok(json.String("null")) -> NullValue
    Ok(json.String("object")) -> record_shape(fields, depth)
    Ok(json.String("array")) ->
      case list.key_find(fields, "items") {
        Ok(items) -> Sequence(shape_at(items, depth + 1))
        Error(Nil) -> RawArray
      }
    Ok(json.Array(types)) -> nullable_shape(types, fields, depth)
    _ -> ValueFallback("undeclared or unsupported type")
  }
}

fn string_shape(fields: List(#(String, JsonValue))) -> Shape {
  case list.key_find(fields, "const"), list.key_find(fields, "enum") {
    Ok(json.String(value)), _ -> Enumeration([value])
    Ok(_), _ -> ValueFallback("string const is not a string")
    Error(Nil), Ok(json.Array(values)) ->
      case
        list.try_map(values, fn(value) {
          case value {
            json.String(text) -> Ok(text)
            _ -> Error(Nil)
          }
        })
      {
        Ok(values) if values != [] -> Enumeration(dedupe(values))
        _ -> ValueFallback("string enum is empty or contains nonstrings")
      }
    Error(Nil), Error(Nil) -> Primitive(ScalarString)
    Error(Nil), Ok(_) -> ValueFallback("enum is not an array")
  }
}

fn nullable_shape(
  types: List(JsonValue),
  fields: List(#(String, JsonValue)),
  depth: Int,
) -> Shape {
  let nonnull = list.filter(types, fn(t) { t != json.String("null") })
  case nonnull, list.contains(types, json.String("null")) {
    [json.String(kind)], True ->
      Nullable(declared_shape(
        list.key_set(fields, "type", json.String(kind)),
        depth + 1,
      ))
    _, _ -> ValueFallback("type array is not one type plus null")
  }
}

fn record_shape(fields: List(#(String, JsonValue)), depth: Int) -> Shape {
  case list.key_find(fields, "properties") {
    Ok(json.Object(_)) ->
      case record_fields(fields, depth) {
        Ok(properties) -> Record(properties, object_openness(fields))
        Error(reason) -> ValueFallback(reason)
      }
    Error(Nil) ->
      case list.key_find(fields, "additionalProperties") {
        Ok(json.Object(_) as item) -> Mapping(shape_at(item, depth + 1))
        Ok(json.Bool(False)) -> Record([], Closed)
        _ -> RawObject
      }
    Ok(_) -> ValueFallback("properties is not an object")
  }
}

fn object_openness(fields: List(#(String, JsonValue))) -> Openness {
  case list.key_find(fields, "additionalProperties") {
    Ok(json.Bool(False)) -> Closed
    _ -> Open
  }
}

fn record_fields(
  fields: List(#(String, JsonValue)),
  depth: Int,
) -> Result(List(Field), String) {
  use required <- result.try(required_names(fields))
  let properties = case list.key_find(fields, "properties") {
    Ok(json.Object(properties)) -> properties
    _ -> []
  }
  let declared = first_declarations(properties)
  let required_set = set.from_list(required)
  let ordered =
    list.append(
      required,
      dedupe(list.map(properties, fn(p) { p.0 }))
        |> list.filter(fn(n) { !set.contains(required_set, n) }),
    )
  Ok(
    list.map(ordered, fn(original) {
      let presence = case set.contains(required_set, original) {
        True -> Required
        False -> OptionalField
      }
      case dict.get(declared, original) {
        Error(Nil) ->
          Field(
            original,
            ValueFallback("required but undeclared"),
            presence,
            None,
            None,
          )
        Ok(value) -> {
          let annotations = case value {
            json.Object(fs) -> fs
            _ -> []
          }
          Field(
            original,
            shape_at(value, depth + 1),
            presence,
            note_of(annotations),
            list.key_find(annotations, "default")
              |> result.map(Some)
              |> result.unwrap(None),
          )
        }
      }
    }),
  )
}

/// Returns all top-level input fields in required-first order. Malformed input
/// preserves the original whole-value form through an explicit error.
///
/// ## Examples
///
/// ```gleam
/// assert schema.input_fields(json.Null) == Error("inputSchema is not an object")
/// ```
pub fn input_fields(value: JsonValue) -> Result(List(Field), String) {
  use _ <- result.try(top_level(value))
  case value {
    json.Object(fields) -> record_fields(fields, 0)
    _ -> Error("inputSchema is not an object")
  }
}

/// Refuses oversized schemas before recursive planning or rendering. This
/// bounded walk covers annotations and default values as well as shape nodes.
///
/// ## Examples
///
/// ```gleam
/// assert schema.check_budget([json.Null]) == Ok(Nil)
/// ```
pub fn check_budget(values: List(JsonValue)) -> Result(Nil, String) {
  budget_loop(list.map(values, fn(v) { #(v, 0) }), 0, 0)
}

// The budget is checked before even the empty worklist succeeds: a terminal
// string or default can exhaust bytes without leaving a child to inspect.
fn budget_loop(
  pending: List(#(JsonValue, Int)),
  nodes: Int,
  bytes: Int,
) -> Result(Nil, String) {
  use _ <- result.try(case nodes > 16_384 || bytes > 262_144 {
    True -> Error("schema exceeds 16384 nodes or 262144 text bytes")
    False -> Ok(Nil)
  })
  case pending {
    [] -> Ok(Nil)
    [#(value, depth), ..rest] ->
      case nodes >= 16_384 || bytes >= 262_144 || depth > 32 {
        True ->
          Error("schema exceeds 16384 nodes, 262144 text bytes, or depth 32")
        False -> {
          let #(children, added) = case value {
            json.Object(fields) -> #(
              list.map(fields, fn(p) { #(p.1, depth + 1) }),
              list.fold(fields, 0, fn(n, p) { n + string.byte_size(p.0) }),
            )
            json.Array(items) -> #(
              list.map(items, fn(v) { #(v, depth + 1) }),
              0,
            )
            json.String(text) -> #([], string.byte_size(text))
            json.Int(value) -> #([], string.byte_size(int.to_string(value)))
            json.Float(value) -> #([], string.byte_size(float.to_string(value)))
            _ -> #([], 0)
          }
          budget_loop(list.append(children, rest), nodes + 1, bytes + added)
        }
      }
  }
}

// Branches are typed only when the declared shapes prove exclusivity without
// interpreting annotations such as ranges or patterns. Otherwise a field
// remains a value, rather than rejecting valid wire data as ambiguous.
fn union_shape(branches: List(Shape)) -> Shape {
  case branches_disjoint(branches) {
    True -> {
      let nonnull = list.filter(branches, fn(branch) { branch != NullValue })
      case list.contains(branches, NullValue), nonnull {
        True, [inner] -> Nullable(inner)
        True, [] -> NullValue
        True, rest -> Nullable(Alternatives(rest))
        False, rest -> Alternatives(rest)
      }
    }
    False -> ValueFallback("oneOf branches are not structurally disjoint")
  }
}

/// Proves exclusivity from the actual structural branch plans. Rendering may
/// widen a field after a name collision, so the generator repeats this check
/// over rendered kinds before composing an exactly-one decoder.
///
/// ## Examples
///
/// ```gleam
/// assert schema.branches_disjoint([schema.Primitive(schema.ScalarString), schema.NullValue])
/// ```
pub fn branches_disjoint(branches: List(Shape)) -> Bool {
  case branches {
    [] -> True
    [branch, ..rest] ->
      list.all(rest, disjoint(branch, _)) && branches_disjoint(rest)
  }
}

fn disjoint(left: Shape, right: Shape) -> Bool {
  case left, right {
    Alternatives(branches), other -> list.all(branches, disjoint(_, other))
    other, Alternatives(branches) -> list.all(branches, disjoint(other, _))
    Nullable(inner), other ->
      disjoint(NullValue, other) && disjoint(inner, other)
    other, Nullable(inner) ->
      disjoint(other, NullValue) && disjoint(other, inner)
    Enumeration(a), Enumeration(b) -> !list.any(a, list.contains(b, _))
    Record(a, _), Record(b, _) ->
      list.any(a, fn(field) {
        field.presence == Required
        && list.any(b, fn(other) {
          other.presence == Required
          && field.original == other.original
          && disjoint(field.shape, other.shape)
        })
      })
    _, _ ->
      shape_category(left) != "unknown"
      && shape_category(right) != "unknown"
      && shape_category(left) != shape_category(right)
  }
}

fn shape_category(shape: Shape) -> String {
  case shape {
    Primitive(ScalarString) | Enumeration(_) -> "string"
    Primitive(ScalarInt) | Primitive(ScalarFloat) -> "number"
    Primitive(ScalarBool) -> "boolean"
    Record(_, _) | Mapping(_) | RawObject -> "object"
    Sequence(_) | RawArray -> "array"
    NullValue -> "null"
    _ -> "unknown"
  }
}
