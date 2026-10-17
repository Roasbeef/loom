//// The slice of `gleam export package-interface` that the prelude generator
//// reads, and a total decoder for it.
////
//// The compiler's JSON describes everything about a package. The generator
//// needs only the public surface: which types, constants and functions each
//// module exports, with their documentation and their types. Decoding into
//// the records below drops the rest (deprecation notices, target
//// implementations, the package version) at the boundary, so the renderer
//// works with values of the right shape and never with raw JSON.
////
//// ## Totality
////
//// A decoder here either returns every field of a value or fails with the
//// path of the field that is wrong. A type node of an unknown `kind` is a
//// failure, not a guess, because the generator would otherwise print a type
//// the compiler never described. Fields the compiler omits, or writes as
//// `null` (a missing label, no constructors, no documentation), decode to
//// their empty value, which is how the Python generator read them.
////
//// ## Documentation comes in two shapes
////
//// A module's documentation is a list of lines. A type's, constant's and
//// function's is one string. Both are decoded to one string with newlines,
//// and the renderer splits it again, so only this module knows about the
//// difference.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/string

/// One module's public surface.
pub type Module {
  Module(
    /// The module's own documentation, one string with newlines.
    documentation: String,
    /// Type aliases by name.
    type_aliases: Dict(String, TypeAlias),
    /// Custom types by name.
    types: Dict(String, TypeDeclaration),
    /// Constants by name.
    constants: Dict(String, Constant),
    /// Functions by name.
    functions: Dict(String, FunctionDeclaration),
  )
}

/// A type as the compiler describes it in a signature.
pub type Type {
  /// A named type with its arguments, written `module.Name(arguments)`. The
  /// module is the full path, such as `cap/fs`; `gleam` is the prelude.
  Named(module: String, name: String, parameters: List(Type))

  /// A type variable. The compiler numbers them and Gleam names them.
  Variable(id: Int)

  /// A function type.
  FunctionType(parameters: List(Type), return: Type)

  /// A tuple type.
  Tuple(elements: List(Type))
}

/// A parameter of a function or constructor.
pub type Parameter {
  Parameter(
    /// The label a caller writes. The compiler records no other name, so an
    /// unlabelled parameter has none.
    label: Option(String),
    /// The parameter's type.
    type_: Type,
  )
}

/// `pub type Name = Target`.
pub type TypeAlias {
  TypeAlias(
    /// The alias's documentation.
    documentation: String,
    /// How many type parameters it takes.
    parameters: Int,
    /// The type it stands for.
    alias: Type,
  )
}

/// A custom type and its constructors. An opaque or external type has none.
pub type TypeDeclaration {
  TypeDeclaration(
    /// The type's documentation.
    documentation: String,
    /// How many type parameters it takes.
    parameters: Int,
    /// Its public constructors.
    constructors: List(Constructor),
  )
}

/// One constructor of a custom type.
pub type Constructor {
  Constructor(
    /// The constructor's name.
    name: String,
    /// Its documentation.
    documentation: String,
    /// Its fields.
    parameters: List(Parameter),
  )
}

/// `pub const name: Type`.
pub type Constant {
  Constant(
    /// The constant's documentation.
    documentation: String,
    /// Its type.
    type_: Type,
  )
}

/// `pub fn name(parameters) -> return`.
pub type FunctionDeclaration {
  FunctionDeclaration(
    /// The function's documentation.
    documentation: String,
    /// Its parameters in order.
    parameters: List(Parameter),
    /// Its return type.
    return: Type,
  )
}

/// Parses the JSON that `gleam export package-interface` writes into a map of
/// module name to public surface.
///
/// ## Examples
///
/// ```gleam
/// // interface.parse("{\"modules\": {}}")
/// // -> Ok(dict.new())
/// ```
pub fn parse(text: String) -> Result(Dict(String, Module), json.DecodeError) {
  json.parse(text, {
    use modules <- decode.field("modules", decode.dict(decode.string, module()))
    decode.success(modules)
  })
}

/// Explains why the interface did not parse, with the path of the first bad
/// field when the JSON was well formed.
///
/// ## Examples
///
/// ```gleam
/// // interface.describe(json.UnexpectedEndOfInput)
/// // -> "the interface ended before the JSON did"
/// ```
pub fn describe(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "the interface ended before the JSON did"

    json.UnexpectedByte(byte) ->
      "unexpected byte " <> byte <> " in the interface"

    json.UnexpectedSequence(sequence) ->
      "unexpected sequence " <> sequence <> " in the interface"

    json.UnableToDecode(errors) ->
      errors
      |> list.map(describe_field)
      |> string.join("; ")
  }
}

/// One decoding failure as `path: expected X, found Y`.
fn describe_field(error: decode.DecodeError) -> String {
  let path = case error.path {
    [] -> "(top level)"
    segments -> string.join(segments, ".")
  }

  path <> ": expected " <> error.expected <> ", found " <> error.found
}

/// A module's surface.
fn module() -> Decoder(Module) {
  use documentation <- decode.optional_field(
    "documentation",
    "",
    documentation(),
  )
  use type_aliases <- decode.optional_field(
    "type-aliases",
    dict.new(),
    decode.dict(decode.string, type_alias()),
  )
  use types <- decode.optional_field(
    "types",
    dict.new(),
    decode.dict(decode.string, type_declaration()),
  )
  use constants <- decode.optional_field(
    "constants",
    dict.new(),
    decode.dict(decode.string, constant()),
  )
  use functions <- decode.optional_field(
    "functions",
    dict.new(),
    decode.dict(decode.string, function_declaration()),
  )

  decode.success(Module(
    documentation:,
    type_aliases:,
    types:,
    constants:,
    functions:,
  ))
}

/// Documentation as one string, whichever shape the compiler wrote it in:
/// a string, a list of lines, or `null`.
fn documentation() -> Decoder(String) {
  decode.one_of(decode.string, or: [
    decode.list(decode.string) |> decode.map(string.join(_, "\n")),
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  ])
}

/// A list that may be absent or `null`, which means empty.
fn list_or_empty(of inner: Decoder(a)) -> Decoder(List(a)) {
  decode.optional(decode.list(inner))
  |> decode.map(option.unwrap(_, []))
}

/// A type alias.
fn type_alias() -> Decoder(TypeAlias) {
  use documentation <- decode.optional_field(
    "documentation",
    "",
    documentation(),
  )
  use parameters <- decode.optional_field("parameters", 0, decode.int)
  use alias <- decode.field("alias", type_node())

  decode.success(TypeAlias(documentation:, parameters:, alias:))
}

/// A custom type.
fn type_declaration() -> Decoder(TypeDeclaration) {
  use documentation <- decode.optional_field(
    "documentation",
    "",
    documentation(),
  )
  use parameters <- decode.optional_field("parameters", 0, decode.int)
  use constructors <- decode.optional_field(
    "constructors",
    [],
    list_or_empty(of: constructor()),
  )

  decode.success(TypeDeclaration(documentation:, parameters:, constructors:))
}

/// A constructor.
fn constructor() -> Decoder(Constructor) {
  use name <- decode.field("name", decode.string)
  use documentation <- decode.optional_field(
    "documentation",
    "",
    documentation(),
  )
  use parameters <- decode.optional_field(
    "parameters",
    [],
    list_or_empty(of: parameter()),
  )

  decode.success(Constructor(name:, documentation:, parameters:))
}

/// A constant.
fn constant() -> Decoder(Constant) {
  use documentation <- decode.optional_field(
    "documentation",
    "",
    documentation(),
  )
  use type_ <- decode.field("type", type_node())

  decode.success(Constant(documentation:, type_:))
}

/// A function.
fn function_declaration() -> Decoder(FunctionDeclaration) {
  use documentation <- decode.optional_field(
    "documentation",
    "",
    documentation(),
  )
  use parameters <- decode.optional_field(
    "parameters",
    [],
    list_or_empty(of: parameter()),
  )
  use return <- decode.field("return", type_node())

  decode.success(FunctionDeclaration(documentation:, parameters:, return:))
}

/// A parameter, whose label is `null` when the caller writes none.
fn parameter() -> Decoder(Parameter) {
  use label <- decode.optional_field(
    "label",
    None,
    decode.optional(decode.string),
  )
  use type_ <- decode.field("type", type_node())

  decode.success(Parameter(label:, type_:))
}

/// A type node, recursive because types contain types.
///
/// The `kind` field selects the shape. A kind this decoder does not know is a
/// failure naming it, with a placeholder value that is never used.
fn type_node() -> Decoder(Type) {
  use <- decode.recursive
  use kind <- decode.field("kind", decode.string)

  case kind {
    "named" -> {
      use module <- decode.field("module", decode.string)
      use name <- decode.field("name", decode.string)
      use parameters <- decode.optional_field(
        "parameters",
        [],
        list_or_empty(of: type_node()),
      )

      decode.success(Named(module:, name:, parameters:))
    }

    "variable" -> {
      use id <- decode.field("id", decode.int)

      decode.success(Variable(id:))
    }

    "fn" -> {
      use parameters <- decode.optional_field(
        "parameters",
        [],
        list_or_empty(of: type_node()),
      )
      use return <- decode.field("return", type_node())

      decode.success(FunctionType(parameters:, return:))
    }

    "tuple" -> {
      use elements <- decode.optional_field(
        "elements",
        [],
        list_or_empty(of: type_node()),
      )

      decode.success(Tuple(elements:))
    }

    other ->
      decode.failure(
        Variable(id: 0),
        "a known type kind (named, variable, fn, tuple), got "
          <> string.inspect(other),
      )
  }
}
