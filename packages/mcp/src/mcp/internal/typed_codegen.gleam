//// Structural MCP rendering uses only fixed report builders and trusted codec
//// combinators. Server text selects inert literals, identifiers and schema
//// shapes; it never supplies executable statements or decoder callbacks.
////
//// Each structural node contributes its declarations to both outputs, so the
//// visible surface cannot invent a type the compiler never sees. The raw
//// control token in encoder templates cannot occur in escaped server
//// literals; encoded replaces it only with trusted generator expressions.
//// Trusted ordinal keys own declaration identity; module-wide allocation
//// prefers a nearby semantic name and adds a compact ordinal only on
//// collision. Names never accumulate a recursive schema path, and bounded
//// ASCII spellings remain below BEAM's 255-byte atom limit.
////
//// ## Flow
////
//// `render` → `facade` → `typed_facade` → `members` → `node` → `encoded`
////
//// 1. `render` sorts the tools and chooses a collision-free helper namespace
////    with `helper_prefix`, then gathers `imports` for what the facades use.
//// 2. `facade` plans both directions once, for allocation and for emission.
//// 3. `typed_facade` builds the optional record and the defaults constant.
//// 4. `members` and `node` recursively derive types, encoders and decoders
////    together, through `object_node`, `union_node`, `enum_node` and `leaf`.
//// 5. `encoded` fills an encoder template, and `function_source` emits it.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/json
import gleam_mcp/protocol
import mcp/internal/render_text as codegen
import mcp/internal/type_name
import mcp/name
import mcp/schema

/// Both outputs are derived from the same declarations and signatures.
pub type Rendered {
  Rendered(
    /// Loadable Gleam source.
    source: String,
    /// Model-visible declarations and signatures.
    surface: String,
  )
}

type Node {
  Node(
    kind: schema.Shape,
    type_name: String,
    encode: String,
    decoder: String,
    definitions: List(String),
    next: Int,
    names: List(#(String, String)),
  )
}

// Trusted ordinal keys distinguish tools, directions, nodes and variants.
// Server text supplies only a preferred display spelling; allocation resolves
// every declaration and constructor together before source emission.
type Direction {
  Input(tool: Int)
  Output(tool: Int)
}

type Scope {
  Scope(direction: Direction, semantic: String, allocated: Dict(String, String))
}

// An encoder template owns whether its payload is consumed. Imported module
// aliases and nested callback locals cannot masquerade as uses of that payload.
type Usage {
  Used
  Ignored
}

type Parameter {
  Parameter(label: String, type_name: String, usage: Usage)
}

type Member {
  Member(field: schema.Field, label: String, node: Node)
}

type Facade {
  Facade(
    name: String,
    doc: String,
    signature: String,
    source: String,
    definitions: List(String),
    defaults: String,
    names: List(#(String, String)),
  )
}

/// Renders bounded structural plans. The caller checks aggregate schema and
/// rendered byte budgets and applies the final attribute scanner.
///
/// ## Examples
///
/// ```gleam
/// typed_codegen.render("github", "github", tools, digest)
/// // -> Matching source and discovery declarations.
/// ```
pub fn render(
  server: String,
  segment: String,
  tools: List(protocol.ToolDescriptor),
  digest: fn(String) -> String,
) -> Rendered {
  let tools =
    list.sort(tools, fn(a, b) {
      string.compare(name.mangle(a.name, digest), name.mangle(b.name, digest))
    })
  let tool_names = list.map(tools, fn(t) { name.mangle(t.name, digest) })
  let prefix = helper_prefix(tool_names, "mcp_generated_")
  let planned =
    list.index_map(tools, fn(tool, index) {
      facade(server, tool, index, prefix, tool_names, dict.new(), digest)
    })

  // The first pass collects declaration identities. Allocation reserves all
  // semantic candidates before a second pass emits syntax with settled names;
  // no replacement ever traverses a server literal or documentation string.
  let allocated = type_name.allocate(list.flat_map(planned, fn(f) { f.names }))
  let facades =
    list.index_map(tools, fn(tool, index) {
      facade(server, tool, index, prefix, tool_names, allocated, digest)
    })

  // Tool order fixes ordinal namespaces before any structural declaration is
  // emitted. Reordered discovery pages therefore produce identical modules.
  let definitions = list.flat_map(facades, fn(f) { f.definitions })
  let bodies = list.map(facades, fn(f) { f.source })
  let header =
    "//// Generated MCP facade for "
    <> codegen.clean(server, 120)
    <> ".\n//// Descriptions are the server's own text.\n"
  let content = string.join(list.append(definitions, bodies), "\n\n")

  // Both consumers receive the same declarations. Discovery omits general
  // type commentary to spend its bounded surface on callable information.
  let surface_definitions =
    list.map(definitions, fn(definition) {
      string.split(definition, "\n")
      |> list.filter(fn(line) {
        !string.starts_with(string.trim(line), "///")
        || string.starts_with(string.trim(line), "/// Wire literal ")
      })
      |> string.join("\n")
    })
  let source = header <> imports(content, facades) <> "\n" <> content <> "\n"
  let surface =
    "### cap/mcp/"
    <> segment
    <> "\nDescriptions below are the server's own text, not Loom's.\nOptional fields use Option; None omits a key, while Some(None) encodes explicit null.\nUse each tool's defaults constant to omit all optional fields.\n\n"
    <> string.join(
      list.append(
        surface_definitions,
        list.map(facades, fn(f) {
          f.doc <> "\n" <> f.defaults <> "\n" <> f.signature
        }),
      ),
      "\n\n",
    )
    <> "\n"
  Rendered(source, surface)
}

fn helper_prefix(names: List(String), prefix: String) -> String {
  case list.any(names, string.starts_with(_, prefix)) {
    True -> helper_prefix(names, prefix <> "x_")
    False -> prefix
  }
}

fn imports(content: String, facades: List(Facade)) -> String {
  let base = case facades {
    [_, ..] -> [
      "import cap/internal/mcp as internal",
      "import cap/mcp",
      "import cap/report",
    ]
    [] -> []
  }
  let tokens = source_tokens(content)
  let codec = case string.contains(tokens, "codec.") {
    True -> ["import cap/internal/mcp_codec as codec"]
    False -> []
  }
  let listed = case string.contains(tokens, "list.") {
    True -> ["import gleam/list"]
    False -> []
  }

  // Option constructors are imported only when generator syntax uses them;
  // words inside server comments, enum literals and identifiers do not count.
  let option_type = case string.contains(tokens, "Option(") {
    True -> ["type Option"]
    False -> []
  }
  let none = case token_contains(tokens, "None") {
    True -> ["None"]
    False -> []
  }
  let some = case token_contains(tokens, "Some") {
    True -> ["Some"]
    False -> []
  }
  let opts = list.flatten([option_type, none, some])
  let optional = case opts {
    [] -> []
    _ -> ["import gleam/option.{" <> string.join(opts, ", ") <> "}"]
  }
  string.join(list.flatten([base, codec, listed, optional]), "\n")
}

fn facade(
  server: String,
  tool: protocol.ToolDescriptor,
  index: Int,
  prefix: String,
  tool_names: List(String),
  allocated: Dict(String, String),
  digest: fn(String) -> String,
) -> Facade {
  let function = name.mangle(tool.name, digest)
  let stem = Scope(Input(index), pascal(function), allocated)
  let default_name = case list.contains(tool_names, function <> "_defaults") {
    True -> prefix <> function <> "_defaults"
    False -> function <> "_defaults"
  }
  let intro =
    docs(case tool.description {
      None -> "Tool " <> tool.name <> "."
      Some(description) -> description
    })

  // Advertised structured output owns its total decoder. A tool without an
  // output schema retains the existing ToolResult envelope and error channel.
  let output = case tool.output_schema {
    None -> None
    Some(value) ->
      Some(node(
        schema.shape(value),
        Scope(Output(index), stem.semantic <> "Result", allocated),
        0,
        digest,
      ))
  }
  let intro =
    intro
    <> case output {
      None -> ""
      Some(n) ->
        case shape_note(n.kind) {
          "" -> ""
          note -> "\n" <> docs("Output" <> note <> ".")
        }
    }
  let return_type = case output {
    None -> "mcp.ToolResult"
    Some(n) -> n.type_name
  }
  let output_definitions = case output {
    None -> []
    Some(n) -> n.definitions
  }
  let output_names = case output {
    None -> []
    Some(n) -> n.names
  }
  let invoke = case output {
    None -> "internal.invoke"
    Some(_) -> "internal.invoke_typed"
  }
  let decoded = case output {
    None -> ""
    Some(n) -> ",\n    " <> n.decoder
  }

  // A malformed top-level input preserves the entire arguments object. Only
  // an independently unsupported field narrows to a local Value fallback.
  let planned = schema.input_fields(tool.input_schema)
  case planned {
    Error(reason) -> {
      let documentation =
        intro
        <> "\n"
        <> docs(
          "Input schema could not be rendered: "
          <> reason
          <> "; pass the entire arguments object.",
        )
      let params = [Parameter("arguments", "report.Value", Used)]
      let body =
        "  "
        <> invoke
        <> "(\n    "
        <> codegen.lit(server)
        <> ",\n    "
        <> codegen.lit(tool.name)
        <> ",\n    arguments"
        <> decoded
        <> ",\n  )"
      Facade(
        function,
        documentation,
        signature(function, params, return_type),
        function_source(documentation, function, params, return_type, body),
        output_definitions,
        "",
        output_names,
      )
    }
    Ok(fields) ->
      typed_facade(
        server,
        tool,
        function,
        stem,
        default_name,
        intro,
        fields,
        output_definitions,
        output_names,
        invoke,
        decoded,
        return_type,
        digest,
      )
  }
}

fn typed_facade(
  server: String,
  tool: protocol.ToolDescriptor,
  function: String,
  stem: Scope,
  default_name: String,
  intro: String,
  fields: List(schema.Field),
  output_definitions: List(String),
  output_names: List(#(String, String)),
  invoke: String,
  decoded: String,
  return_type: String,
  digest: fn(String) -> String,
) -> Facade {
  let #(members, _) = members(fields, stem, 1, digest)
  let collisions =
    name.first_collision(
      list.map(members, fn(m) { #(m.field.original, m.label) }),
    )
  case collisions {
    Error(_) -> {
      let documentation =
        intro
        <> "\n"
        <> docs(
          "Parameters collide after renaming; pass the entire arguments object.",
        )
      let params = [Parameter("arguments", "report.Value", Used)]
      let body =
        "  "
        <> invoke
        <> "(\n    "
        <> codegen.lit(server)
        <> ",\n    "
        <> codegen.lit(tool.name)
        <> ",\n    arguments"
        <> decoded
        <> ",\n  )"
      Facade(
        function,
        documentation,
        signature(function, params, return_type),
        function_source(documentation, function, params, return_type, body),
        output_definitions,
        "",
        output_names,
      )
    }
    Ok(Nil) -> {
      let required =
        list.filter(members, fn(m) { m.field.presence == schema.Required })
      let optional =
        list.filter(members, fn(m) { m.field.presence == schema.OptionalField })
      let options_key =
        "McpT" <> int.to_string(stem.direction.tool) <> "Options"
      let options_semantic = semantic_name(stem.semantic <> "Options")
      let options_type = allocated_name(stem, options_key, options_semantic)
      let declaration = record_definition(options_type, optional)
      let defaults =
        "/// Omit each optional field; the server applies its declared defaults.\npub const "
        <> default_name
        <> " = "
        <> options_type
        <> case optional {
          [] -> ""
          _ ->
            "("
            <> string.join(
              list.map(optional, fn(m) { m.label <> ": None" }),
              ", ",
            )
            <> ")"
        }
      let params =
        list.append(
          list.map(required, fn(m) {
            Parameter(m.label, m.node.type_name, payload_usage(m.node))
          }),
          [
            Parameter("options", options_type, case optional {
              [] -> Ignored
              _ -> Used
            }),
          ],
        )

      // Required wire keys precede optional fragments. None contributes no
      // fragment, so callers cannot append a duplicate required key through
      // the old untyped options list. Explicit nullable values stay Some(None).
      let required_pairs =
        "["
        <> string.join(
          list.map(required, fn(m) {
            "#("
            <> codegen.lit(m.field.original)
            <> ", "
            <> encoded(m.node, m.label)
            <> ")"
          }),
          ", ",
        )
        <> "]"
      let optional_pairs =
        list.map(optional, fn(m) {
          "codec.optional("
          <> codegen.lit(m.field.original)
          <> ", options."
          <> m.label
          <> ", "
          <> encoder_function(m.node, "value")
          <> ")"
        })
      let pairs = case optional_pairs {
        [] -> required_pairs
        _ ->
          "list.flatten(["
          <> string.join([required_pairs, ..optional_pairs], ", ")
          <> "])"
      }
      let body =
        "  "
        <> invoke
        <> "(\n    "
        <> codegen.lit(server)
        <> ",\n    "
        <> codegen.lit(tool.name)
        <> ",\n    report.object("
        <> pairs
        <> ")"
        <> decoded
        <> ",\n  )"

      // Defaults omit fields rather than guessing how the remote server
      // applies annotation defaults. The discovery notes retain that metadata.
      let documentation =
        intro <> "\n" <> string.join(list.map(members, member_doc), "\n")
      let definitions =
        list.flatten([
          output_definitions,
          list.flat_map(members, fn(m) { m.node.definitions }),
          [declaration, defaults],
        ])
      Facade(
        function,
        documentation,
        signature(function, params, return_type),
        function_source(documentation, function, params, return_type, body),
        definitions,
        "",
        list.flatten([
          output_names,
          list.flat_map(members, fn(m) { m.node.names }),
          [#(options_key, options_semantic)],
        ]),
      )
    }
  }
}

fn member_doc(member: Member) -> String {
  let fallback = shape_note(member.node.kind)
  let default = case member.field.default {
    None -> ""
    Some(value) ->
      "; schema default " <> codegen.clean(json.to_string(value), 120)
  }
  let note = case member.field.note {
    None -> ""
    Some(text) -> "; " <> codegen.clean(text, 120)
  }
  docs(
    "- "
    <> member.label
    <> ": wire "
    <> codegen.clean(member.field.original, 120)
    <> fallback
    <> default
    <> note
    <> ".",
  )
}

fn shape_note(shape: schema.Shape) -> String {
  case shape {
    schema.ValueFallback(reason) -> "; report.Value fallback: " <> reason
    schema.Record(fields, _) ->
      string.concat(
        list.map(fields, fn(f) {
          case shape_note(f.shape) {
            "" -> ""
            note -> "; field " <> f.original <> note
          }
        }),
      )
    schema.Sequence(inner) | schema.Mapping(inner) | schema.Nullable(inner) ->
      shape_note(inner)
    schema.Alternatives(branches) ->
      string.concat(list.map(branches, shape_note))
    _ -> ""
  }
}

// Each subtree receives a fresh identity after its parent. A field starts a
// nearby semantic name instead of retaining every ancestor in its spelling.
fn members(
  fields: List(schema.Field),
  stem: Scope,
  start: Int,
  digest: fn(String) -> String,
) -> #(List(Member), Int) {
  list.map_fold(fields, start, fn(counter, field) {
    let label = field_label(field.original, digest)
    let child =
      node(field.shape, Scope(..stem, semantic: pascal(label)), counter, digest)
    #(child.next, Member(field, label, child))
  })
  |> fn(pair) { #(pair.1, pair.0) }
}

// Type, encoder and decoder are one structural decision. Input and output
// stems are separate so a hostile property cannot collide with a result type.
fn node(
  shape: schema.Shape,
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Node {
  case shape {
    schema.Primitive(schema.ScalarString) ->
      leaf(shape, "String", "report.string(\u{1})", "codec.string()", counter)
    schema.Primitive(schema.ScalarInt) ->
      leaf(shape, "Int", "report.int(\u{1})", "codec.int()", counter)
    schema.Primitive(schema.ScalarFloat) ->
      leaf(shape, "Float", "report.float(\u{1})", "codec.number()", counter)
    schema.Primitive(schema.ScalarBool) -> boolean_node(shape, stem, counter)
    schema.Enumeration(values) ->
      enum_node(shape, values, stem, counter, digest)
    schema.NullValue ->
      leaf(shape, "Nil", "report.null()", "codec.null()", counter)
    schema.RawObject ->
      leaf(
        shape,
        "List(#(String, report.Value))",
        "report.object(\u{1})",
        "codec.dictionary(codec.value())",
        counter,
      )
    schema.RawArray ->
      leaf(
        shape,
        "List(report.Value)",
        "report.list(\u{1})",
        "codec.list(codec.value())",
        counter,
      )
    schema.ValueFallback(_) ->
      leaf(shape, "report.Value", "\u{1}", "codec.value()", counter)
    schema.Sequence(inner) ->
      container_node(ListContainer, inner, stem, counter, digest)
    schema.Mapping(inner) ->
      container_node(MapContainer, inner, stem, counter, digest)
    schema.Nullable(inner) ->
      container_node(NullableContainer, inner, stem, counter, digest)
    schema.Record(fields, openness) ->
      object_node(fields, openness, stem, counter, digest)
    schema.Alternatives([inner]) -> node(inner, stem, counter, digest)
    schema.Alternatives(branches) -> union_node(branches, stem, counter, digest)
  }
}

fn leaf(
  shape: schema.Shape,
  type_name: String,
  encode: String,
  decoder: String,
  counter: Int,
) -> Node {
  Node(shape, type_name, encode, decoder, [], counter + 1, [])
}

// A named two-variant boolean puts wire meaning at each call site instead of
// making the caller remember the polarity of a naked Bool parameter.
fn boolean_node(shape: schema.Shape, stem: Scope, counter: Int) -> Node {
  let identifier = node_identifier(stem, counter)
  let key = node_prefix(stem.direction, counter)
  let semantic = semantic_name(stem.semantic)
  let enabled = allocated_name(stem, key <> "V0", semantic <> "Enabled")
  let disabled = allocated_name(stem, key <> "V1", semantic <> "Disabled")

  // Both variants retain the same wire polarity in input and output codecs.
  let definition =
    "/// Named boolean meaning for this wire field.\npub type "
    <> identifier
    <> " {\n  /// Encode true.\n  "
    <> enabled
    <> "\n\n  /// Encode false.\n  "
    <> disabled
    <> "\n}"
  let encode =
    "case \u{1} { "
    <> enabled
    <> " -> report.bool(True) "
    <> disabled
    <> " -> report.bool(False) }"
  let decoder =
    "codec.map(codec.boolean(), fn(value) { case value { True -> "
    <> enabled
    <> " False -> "
    <> disabled
    <> " } })"
  Node(shape, identifier, encode, decoder, [definition], counter + 1, [
    #(key, semantic),
    #(key <> "V0", semantic <> "Enabled"),
    #(key <> "V1", semantic <> "Disabled"),
  ])
}

// Enum wire literals remain exact. Their display candidates share the same
// allocator as records and other constructors, including ordinal lookalikes.
fn enum_variants(
  values: List(String),
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> List(#(String, String)) {
  list.index_map(values, fn(value, index) {
    #(
      value,
      allocated_name(
        stem,
        node_prefix(stem.direction, counter) <> "V" <> int.to_string(index),
        semantic_name(stem.semantic <> pascal(name.mangle(value, digest))),
      ),
    )
  })
}

fn enum_node(
  shape: schema.Shape,
  values: List(String),
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Node {
  let identifier = node_identifier(stem, counter)
  let variants = enum_variants(values, stem, counter, digest)
  let definition =
    "/// Closed string values declared by the server.\npub type "
    <> identifier
    <> " {\n"
    <> string.join(
      list.map(variants, fn(v) {
        "  /// Wire literal " <> codegen.clean(v.0, 120) <> ".\n  " <> v.1
      }),
      "\n\n",
    )
    <> "\n}"
  let encode =
    "case \u{1} { "
    <> string.join(
      list.map(variants, fn(v) {
        v.1 <> " -> report.string(" <> codegen.lit(v.0) <> ")"
      }),
      " ",
    )
    <> " }"
  let decoder =
    "codec.one_of(["
    <> string.join(
      list.map(variants, fn(v) {
        "codec.literal(report.string("
        <> codegen.lit(v.0)
        <> "), "
        <> v.1
        <> ")"
      }),
      ", ",
    )
    <> "])"
  Node(shape, identifier, encode, decoder, [definition], counter + 1, [
    #(node_prefix(stem.direction, counter), semantic_name(stem.semantic)),
    ..list.index_map(values, fn(value, index) {
      #(
        node_prefix(stem.direction, counter) <> "V" <> int.to_string(index),
        semantic_name(stem.semantic <> pascal(name.mangle(value, digest))),
      )
    })
  ])
}

// The dispatch type makes non-container shapes unreachable here. Child
// fallback reasons flow back into the enclosing kind for discovery notes.
type Container {
  ListContainer
  MapContainer
  NullableContainer
}

fn container_node(
  container: Container,
  inner: schema.Shape,
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Node {
  let child =
    node(
      inner,
      Scope(..stem, semantic: container_semantic(container, stem.semantic)),
      counter + 1,
      digest,
    )
  let #(type_name, encode, decoder) = case container {
    ListContainer -> #(
      "List(" <> child.type_name <> ")",
      "report.list(list.map(\u{1}, " <> encoder_function(child, "item") <> "))",
      "codec.list(" <> child.decoder <> ")",
    )
    MapContainer -> #(
      "List(#(String, " <> child.type_name <> "))",
      "report.object(list.map(\u{1}, fn(entry) { #(entry.0, "
        <> encoded(child, "entry.1")
        <> ") }))",
      "codec.dictionary(" <> child.decoder <> ")",
    )
    NullableContainer -> #(
      "Option(" <> child.type_name <> ")",
      "codec.nullable_value(\u{1}, " <> encoder_function(child, "item") <> ")",
      "codec.nullable(" <> child.decoder <> ")",
    )
  }
  let shape = case container {
    ListContainer -> schema.Sequence(child.kind)
    MapContainer -> schema.Mapping(child.kind)
    NullableContainer -> schema.Nullable(child.kind)
  }
  Node(
    shape,
    type_name,
    encode,
    decoder,
    child.definitions,
    child.next,
    child.names,
  )
}

// A record decoder establishes object shape and required presence before
// construction. Its open/closed policy is the schema policy, not a heuristic.
fn object_node(
  fields: List(schema.Field),
  openness: schema.Openness,
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Node {
  let identifier = node_identifier(stem, counter)
  let #(members, next) = members(fields, stem, counter + 1, digest)
  case
    name.first_collision(
      list.map(members, fn(m) { #(m.field.original, m.label) }),
    )
  {
    Error(_) ->
      leaf(
        schema.ValueFallback("record fields collide after renaming"),
        "report.Value",
        "\u{1}",
        "codec.value()",
        next,
      )
    Ok(Nil) -> {
      let encode = object_encode(members, "\u{1}.", None)
      let decoder =
        object_decoder(
          members,
          openness,
          constructor(
            identifier,
            list.map(members, fn(member) {
              member.label <> ": " <> member.label
            }),
          ),
          None,
        )
      Node(
        schema.Record(
          list.map(members, fn(m) {
            schema.Field(..m.field, shape: m.node.kind)
          }),
          openness,
        ),
        identifier,
        encode,
        decoder,
        list.append(list.flat_map(members, fn(m) { m.node.definitions }), [
          record_definition(identifier, members),
        ]),
        next,
        [
          #(node_prefix(stem.direction, counter), semantic_name(stem.semantic)),
          ..list.flat_map(members, fn(m) { m.node.names })
        ],
      )
    }
  }
}

fn record_definition(identifier: String, members: List(Member)) -> String {
  "/// Named wire properties; optional fields retain absence separately from null.\npub type "
  <> identifier
  <> " {\n  /// Construct this wire record.\n  "
  <> record_constructor(identifier, members)
  <> "\n}"
}

fn record_constructor(identifier: String, members: List(Member)) -> String {
  case members {
    [] -> identifier
    _ ->
      identifier
      <> "(\n"
      <> string.join(
        list.map(members, fn(member) {
          "    /// "
          <> codegen.clean(member.field.original, 100)
          <> " wire property.\n    "
          <> member_declaration(member)
          <> ","
        }),
        "\n",
      )
      <> "\n  )"
  }
}

// A required singleton string field can transfer its wire obligation to a
// constructor. Optional, repeated or nested tags cannot select this path.
type TaggedBranch {
  TaggedBranch(
    fields: List(schema.Field),
    openness: schema.Openness,
    literal: String,
  )
}

type TaggedNode {
  TaggedNode(members: List(Member), openness: schema.Openness, literal: String)
}

fn union_node(
  branches: List(schema.Shape),
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Node {
  case tagged_branches(branches) {
    Some(#(tag, tagged)) ->
      case tagged_union_node(tag, tagged, stem, counter, digest) {
        Ok(rendered) -> rendered
        Error(Nil) -> ordinary_union_node(branches, stem, counter, digest)
      }
    None -> ordinary_union_node(branches, stem, counter, digest)
  }
}

fn tagged_branches(
  branches: List(schema.Shape),
) -> Option(#(String, List(TaggedBranch))) {
  case branches {
    [schema.Record(fields, _), ..] -> {
      let candidates =
        list.filter(fields, fn(field) {
          case field.presence, field.shape {
            schema.Required, schema.Enumeration([_]) -> True
            _, _ -> False
          }
        })
        |> list.sort(fn(a, b) { string.compare(a.original, b.original) })
      list.find_map(candidates, fn(field) {
        use tagged <- result.try(
          list.try_map(branches, tagged_branch(_, field.original)),
        )
        use Nil <- result.try(
          name.first_collision(
            list.map(tagged, fn(branch) { #(branch.literal, branch.literal) }),
          )
          |> result.map_error(fn(_) { Nil }),
        )
        Ok(#(field.original, tagged))
      })
      |> option_from_result
    }
    _ -> None
  }
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn tagged_branch(
  branch: schema.Shape,
  tag: String,
) -> Result(TaggedBranch, Nil) {
  case branch {
    schema.Record(fields, openness) -> {
      use field <- result.try(
        list.find(fields, fn(field) { field.original == tag }),
      )
      case field.presence, field.shape {
        schema.Required, schema.Enumeration([literal]) ->
          Ok(TaggedBranch(fields, openness, literal))
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn tagged_union_node(
  tag: String,
  branches: List(TaggedBranch),
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Result(Node, Nil) {
  let #(next, rendered) =
    list.map_fold(branches, counter + 1, fn(counter, branch) {
      let #(members, next) = members(branch.fields, stem, counter + 1, digest)
      #(next, TaggedNode(members, branch.openness, branch.literal))
    })

  // Recheck the full rendered records, including the constructor-owned tag.
  // The payload projection removes neither presence nor literal exclusivity
  // from the decoder's proof, even when an unrelated field falls back.
  use <- bool.lazy_guard(
    when: !schema.branches_disjoint(
      list.map(rendered, fn(branch) {
        record_shape(branch.members, branch.openness)
      }),
    )
      || list.any(rendered, fn(branch) {
      case
        name.first_collision(
          list.map(branch.members, fn(member) {
            #(member.field.original, member.label)
          }),
        )
      {
        Ok(Nil) -> False
        Error(_) -> True
      }
    }),
    return: fn() { Error(Nil) },
  )
  let key = node_prefix(stem.direction, counter)
  let identifier = node_identifier(stem, counter)
  let variants =
    list.index_map(rendered, fn(branch, index) {
      let variant_key = key <> "V" <> int.to_string(index)
      let semantic =
        semantic_name(
          pascal(name.mangle(branch.literal, digest)) <> stem.semantic,
        )
      #(
        allocated_name(stem, variant_key, semantic),
        branch,
        #(variant_key, semantic),
      )
    })
  let definition =
    "/// Exactly one tagged wire record; the constructor supplies its discriminator.\npub type "
    <> identifier
    <> " {\n"
    <> string.join(
      list.map(variants, fn(variant) {
        "  /// Wire literal "
        <> codegen.clean(variant.1.literal, 120)
        <> ".\n  "
        <> record_constructor(
          variant.0,
          payload_members(variant.1.members, tag),
        )
      }),
      "\n\n",
    )
    <> "\n}"
  let encode =
    "case \u{1} { "
    <> string.join(
      list.map(variants, fn(variant) {
        constructor(
          variant.0,
          list.map(payload_members(variant.1.members, tag), fn(member) {
            member.label
            <> ": "
            <> binding_name(member.label, member_usage(member))
          }),
        )
        <> " -> "
        <> object_encode(variant.1.members, "", Some(#(tag, variant.1.literal)))
      }),
      " ",
    )
    <> " }"
  let decoder =
    "codec.one_of(["
    <> string.join(
      list.map(variants, fn(variant) {
        object_decoder(
          variant.1.members,
          variant.1.openness,
          constructor(
            variant.0,
            list.map(payload_members(variant.1.members, tag), fn(member) {
              member.label <> ": " <> member.label
            }),
          ),
          Some(#(tag, variant.1.literal)),
        )
      }),
      ", ",
    )
    <> "])"
  let payloads =
    list.flat_map(rendered, fn(branch) { payload_members(branch.members, tag) })
  Ok(Node(
    schema.Alternatives(
      list.map(rendered, fn(branch) {
        record_shape(branch.members, branch.openness)
      }),
    ),
    identifier,
    encode,
    decoder,
    list.append(
      list.flat_map(payloads, fn(member) { member.node.definitions }),
      [definition],
    ),
    next,
    list.flatten([
      [#(key, semantic_name(stem.semantic))],
      list.flat_map(payloads, fn(member) { member.node.names }),
      list.map(variants, fn(variant) { variant.2 }),
    ]),
  ))
}

fn payload_members(members: List(Member), tag: String) -> List(Member) {
  list.filter(members, fn(member) { member.field.original != tag })
}

fn member_usage(member: Member) -> Usage {
  case member.field.presence {
    schema.OptionalField -> Used
    schema.Required -> payload_usage(member.node)
  }
}

fn member_declaration(member: Member) -> String {
  let type_name = case member.field.presence {
    schema.Required -> member.node.type_name
    schema.OptionalField -> "Option(" <> member.node.type_name <> ")"
  }
  member.label <> ": " <> type_name
}

// Records and flattened tagged variants share their wire codecs. The optional
// fixed field changes only how the constructor supplies one required literal;
// object keys, openness, presence and nested decoder checks remain identical.
fn object_encode(
  members: List(Member),
  access: String,
  fixed: Option(#(String, String)),
) -> String {
  let fields =
    list.map(members, fn(member) {
      case fixed {
        Some(#(tag, literal)) if member.field.original == tag ->
          "[#("
          <> codegen.lit(tag)
          <> ", report.string("
          <> codegen.lit(literal)
          <> "))]"
        _ ->
          case member.field.presence {
            schema.Required ->
              "[#("
              <> codegen.lit(member.field.original)
              <> ", "
              <> encoded(member.node, access <> member.label)
              <> ")]"
            schema.OptionalField ->
              "codec.optional("
              <> codegen.lit(member.field.original)
              <> ", "
              <> access
              <> member.label
              <> ", "
              <> encoder_function(member.node, "item")
              <> ")"
          }
      }
    })
  "report.object(list.flatten([" <> string.join(fields, ", ") <> "]))"
}

fn record_shape(
  members: List(Member),
  openness: schema.Openness,
) -> schema.Shape {
  schema.Record(
    list.map(members, fn(member) {
      schema.Field(..member.field, shape: member.node.kind)
    }),
    openness,
  )
}

fn object_decoder(
  members: List(Member),
  openness: schema.Openness,
  constructed: String,
  fixed: Option(#(String, String)),
) -> String {
  let openness = case openness {
    schema.Closed -> "codec.RejectAdditional"
    schema.Open -> "codec.AllowAdditional"
  }
  let fields =
    list.map(members, fn(member) {
      case fixed {
        Some(#(tag, literal)) if member.field.original == tag ->
          "use _tag <- codec.field("
          <> codegen.lit(tag)
          <> ", codec.literal(report.string("
          <> codegen.lit(literal)
          <> "), Nil))\n "
        _ -> {
          let field_fn = case member.field.presence {
            schema.Required -> "field"
            schema.OptionalField -> "optional_field"
          }
          "use "
          <> member.label
          <> " <- codec."
          <> field_fn
          <> "("
          <> codegen.lit(member.field.original)
          <> ", "
          <> member.node.decoder
          <> ")\n "
        }
      }
    })
  "codec.object(["
  <> string.join(
    list.map(members, fn(member) { codegen.lit(member.field.original) }),
    ", ",
  )
  <> "], "
  <> openness
  <> ", { "
  <> string.concat(fields)
  <> "codec.success("
  <> constructed
  <> ") })"
}

// Planning proved the branches structurally disjoint. The trusted one_of
// combinator still requires exactly one successful decoder at the wire edge.
fn ordinary_union_node(
  branches: List(schema.Shape),
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Node {
  let identifier = node_identifier(stem, counter)
  let #(next, children) =
    list.map_fold(branches, counter + 1, fn(counter, branch) {
      let child = node(branch, stem, counter, digest)
      #(child.next, child)
    })

  // Rendering can widen a required discriminator inside a nested record.
  // Reprove exclusivity against the rendered kinds, rather than recursively
  // rejecting unrelated fallback fields whose discriminators remain intact.
  use <- bool.lazy_guard(
    when: !schema.branches_disjoint(
      list.map(children, fn(child) { child.kind }),
    ),
    return: fn() {
      leaf(
        schema.ValueFallback("oneOf branch could not be rendered safely"),
        "report.Value",
        "\u{1}",
        "codec.value()",
        next,
      )
    },
  )
  let variants =
    list.index_map(children, fn(child, index) {
      #(
        allocated_name(
          stem,
          node_prefix(stem.direction, counter) <> "V" <> int.to_string(index),
          semantic_name(stem.semantic <> branch_semantic(child.kind)),
        ),
        child,
      )
    })
  let definition =
    "/// Exactly one of these server-declared wire shapes.\npub type "
    <> identifier
    <> " {\n"
    <> string.join(
      list.map(variants, fn(v) {
        "  /// Branch "
        <> v.0
        <> ".\n  "
        <> v.0
        <> "(value: "
        <> v.1.type_name
        <> ")"
      }),
      "\n\n",
    )
    <> "\n}"
  let encode =
    "case \u{1} { "
    <> string.join(
      list.map(variants, fn(v) {
        let body = encoded(v.1, "value")
        v.0
        <> "("
        <> binding_name("value", payload_usage(v.1))
        <> ") -> "
        <> body
      }),
      " ",
    )
    <> " }"
  let decoder =
    "codec.one_of(["
    <> string.join(
      list.map(variants, fn(v) {
        "codec.map(" <> v.1.decoder <> ", " <> v.0 <> ")"
      }),
      ", ",
    )
    <> "])"
  Node(
    schema.Alternatives(list.map(children, fn(child) { child.kind })),
    identifier,
    encode,
    decoder,
    list.append(list.flat_map(children, fn(c) { c.definitions }), [definition]),
    next,
    list.flatten([
      [#(node_prefix(stem.direction, counter), semantic_name(stem.semantic))],
      list.flat_map(children, fn(c) { c.names }),
      list.index_map(children, fn(child, index) {
        #(
          node_prefix(stem.direction, counter) <> "V" <> int.to_string(index),
          semantic_name(stem.semantic <> branch_semantic(child.kind)),
        )
      }),
    ]),
  )
}

// Server literals never contain this raw control token: lit escapes every
// nonprintable codepoint. Replacement can therefore touch generator-owned
// expression holes only, even for hostile fields named cost$ or enum "$".
fn encoded(node: Node, value: String) -> String {
  string.replace(node.encode, "\u{1}", value)
}

// Empty records and null values are zero-arity data constructors. Their
// encoders do not consume a payload, so the generated binding is explicitly
// ignored rather than causing a warnings-as-errors compile failure.
fn constructor(identifier: String, fields: List(String)) -> String {
  case fields {
    [] -> identifier
    _ -> identifier <> "(" <> string.join(fields, ", ") <> ")"
  }
}

fn binding_name(variable: String, usage: Usage) -> String {
  case usage {
    Used -> variable
    Ignored -> "_" <> variable
  }
}

fn payload_usage(node: Node) -> Usage {
  case string.contains(node.encode, "\u{1}") {
    True -> Used
    False -> Ignored
  }
}

fn encoder_function(node: Node, variable: String) -> String {
  let body = encoded(node, variable)
  "fn(" <> binding_name(variable, payload_usage(node)) <> ") { " <> body <> " }"
}

fn node_prefix(direction: Direction, counter: Int) -> String {
  let lane = case direction {
    Input(_) -> "Input"
    Output(_) -> "Output"
  }
  "McpT"
  <> int.to_string(direction.tool)
  <> lane
  <> "N"
  <> int.to_string(counter)
}

fn node_identifier(scope: Scope, counter: Int) -> String {
  allocated_name(
    scope,
    node_prefix(scope.direction, counter),
    semantic_name(scope.semantic),
  )
}

// Escaping this keyword locally avoids exposing a digest at ordinary call
// sites. An explicit type_ field competes for the same label and therefore
// follows the existing field-collision fallback, never silently aliases it.
fn field_label(original: String, digest: fn(String) -> String) -> String {
  case original {
    "type" | "type_" -> "type_"
    _ -> name.mangle_label(original, digest)
  }
}

fn allocated_name(scope: Scope, key: String, semantic: String) -> String {
  case dict.get(scope.allocated, key) {
    Ok(chosen) -> chosen
    Error(Nil) -> key <> semantic
  }
}

fn container_semantic(container: Container, semantic: String) -> String {
  case container {
    NullableContainer -> semantic
    ListContainer | MapContainer ->
      case
        string.ends_with(semantic, "s") && !string.ends_with(semantic, "ss")
      {
        True -> string.drop_end(semantic, 1)
        False -> semantic
      }
  }
}

fn branch_semantic(shape: schema.Shape) -> String {
  case shape {
    schema.Primitive(schema.ScalarString) -> "Text"
    schema.Primitive(schema.ScalarInt) -> "Integer"
    schema.Primitive(schema.ScalarFloat) -> "Number"
    schema.Primitive(schema.ScalarBool) -> "Boolean"
    schema.RawObject | schema.Mapping(_) | schema.Record(_, _) -> "Object"
    schema.RawArray | schema.Sequence(_) -> "Array"
    schema.NullValue -> "Null"
    schema.Nullable(_) -> "Nullable"
    schema.Enumeration(_) -> "Literal"
    schema.Alternatives(_) | schema.ValueFallback(_) -> "Value"
  }
}

// Semantic names are bounded ASCII candidates. Allocation, rather than
// clipping or server text, owns uniqueness after CamelCase becomes an atom.
fn semantic_name(value: String) -> String {
  string.slice(value, 0, 64)
}

fn pascal(value: String) -> String {
  string.split(value, "_")
  |> list.map(fn(piece) {
    string.uppercase(string.slice(piece, 0, 1)) <> string.drop_start(piece, 1)
  })
  |> string.concat
}

fn docs(text: String) -> String {
  codegen.wrap(codegen.clean(text, 400), 72)
  |> list.map(fn(line) { "/// " <> line })
  |> string.join("\n")
}

fn signature(
  name: String,
  params: List(Parameter),
  return_type: String,
) -> String {
  "pub fn "
  <> name
  <> "("
  <> string.join(
    list.map(params, fn(p) { p.label <> ": " <> p.type_name }),
    ", ",
  )
  <> ") -> Result("
  <> return_type
  <> ", mcp.McpError)"
}

fn function_source(
  doc: String,
  name: String,
  params: List(Parameter),
  return_type: String,
  body: String,
) -> String {
  doc
  <> "\n///\n/// ## Examples\n///\n/// ```gleam\n/// // Call this facade from an authorized code-mode program.\n/// ```\npub fn "
  <> name
  <> "(\n"
  <> string.join(
    list.map(params, fn(p) {
      "  "
      <> p.label
      <> " "
      <> binding_name(p.label, p.usage)
      <> ": "
      <> p.type_name
      <> ","
    }),
    "\n",
  )
  <> "\n) -> Result("
  <> return_type
  <> ", mcp.McpError) {\n"
  <> body
  <> "\n}"
}

// Import selection reads generator syntax only. Server literals or prose
// mentioning a module must not manufacture an unused compiler import.
fn source_tokens(source: String) -> String {
  string.split(source, "\n")
  |> list.filter(fn(line) { !string.starts_with(string.trim(line), "///") })
  |> list.map(fn(line) {
    tokens_loop(string.to_graphemes(line), OutsideLiteral, [])
  })
  |> string.concat
}

type LiteralState {
  OutsideLiteral
  InsideLiteral
  EscapedLiteral
}

fn tokens_loop(
  chars: List(String),
  state: LiteralState,
  kept: List(String),
) -> String {
  case chars {
    [] -> string.concat(list.reverse(kept))
    [char, ..rest] ->
      case state, char {
        OutsideLiteral, "\"" -> tokens_loop(rest, InsideLiteral, kept)
        OutsideLiteral, _ -> tokens_loop(rest, OutsideLiteral, [char, ..kept])
        InsideLiteral, "\\" -> tokens_loop(rest, EscapedLiteral, kept)
        InsideLiteral, "\"" -> tokens_loop(rest, OutsideLiteral, kept)
        InsideLiteral, _ -> tokens_loop(rest, InsideLiteral, kept)
        EscapedLiteral, _ -> tokens_loop(rest, InsideLiteral, kept)
      }
  }
}

fn token_contains(code: String, identifier: String) -> Bool {
  let text =
    list.fold(
      ["(", ")", "{", "}", "[", "]", ",", ":", "=", "\n", ".", "\t"],
      code,
      fn(text, punctuation) { string.replace(text, punctuation, " ") },
    )
  list.contains(string.split(text, " "), identifier)
}
