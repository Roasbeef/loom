//// `mcp/schema` — total interpretation of a tool's `inputSchema` into a
//// typed parameter plan.
////
//// `mcp/protocol` carries a listed tool's input schema raw and untrusted;
//// this module is the one place that reads it, and it reads it into an
//// intermediate plan that both the code generator and the prompt-surface
//// renderer consume. The interpretation is deliberately three-tiered and
//// never fails:
////
//// - **Tier 1** — a *required* parameter whose schema fits the typed
////   subset (`string`, `integer`, `number`, `boolean`, or an array of one
////   of those four) becomes a typed argument. Extra annotation keys
////   (`description`, `format`, `default`, `minLength`, …) never
////   disqualify; a string `enum` stays a `String` whose values are doc
////   prose.
//// - **Tier 2** — any other required-parameter schema (nested object,
////   array of objects, `anyOf`/`oneOf`/`allOf`, `$ref`, a type array, a
////   missing type, a boolean schema, or a `required` name with no
////   `properties` entry) becomes a required structured argument. No
////   parameter is ever dropped.
//// - **Tier 3** — an unusable top level (not `{"type": "object"}`,
////   `properties` present but not an object, `required` present but not
////   an array of strings) collapses the whole tool to `WholeValue`: one
////   argument carrying the entire arguments map, with the reason worded
////   for the generated doc comment.
////
//// Optional parameters — everything under `properties` that the
//// top-level `required` array does not name — are never typed arguments;
//// they surface as `Optional` notes and travel through the generated
//// façade's one `options` argument, keyed by original wire name.

import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}

/// The four scalar shapes the typed subset admits.
pub type Scalar {
  /// `{"type": "string"}` — enums included.
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
