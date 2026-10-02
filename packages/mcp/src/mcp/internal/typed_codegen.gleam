//// Structural MCP rendering uses only fixed report builders and trusted codec
//// combinators. Server text selects inert literals, identifiers and schema
//// shapes; it never supplies executable statements or decoder callbacks.
////
//// Reading path: render sorts tools and chooses a collision-free helper
//// namespace; facade plans input and output once; typed_facade builds the
//// optional record and defaults constant; members and node recursively derive
//// types, encoders and decoders together. Each structural node contributes its
//// declarations to both outputs, so the visible surface cannot invent a type
//// the compiler never sees. The raw control token in encoder templates cannot
//// occur in escaped server literals; encoded replaces it only with trusted
//// generator expressions. Trusted tool/direction/node/variant ordinals own
//// identity; at most 64 ASCII display characters follow them. This keeps even
//// deeply nested names below the BEAM 255-byte atom limit after snake casing.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/json
import gleam_mcp/protocol
import mcp/internal/render_text as codegen
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
  )
}

// The ordinal prefix is trusted and appears before every semantic label.
// Decimal ordinals end at fixed alphabetic markers; server text cannot move a
// node into another tool, direction, node or variant constructor namespace.
type Direction {
  Input(tool: Int)
  Output(tool: Int)
}

type Scope {
  Scope(direction: Direction, semantic: String)
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
  let facades =
    list.index_map(tools, fn(tool, index) {
      facade(server, tool, index, prefix, tool_names, digest)
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
  digest: fn(String) -> String,
) -> Facade {
  let function = name.mangle(tool.name, digest)
  let stem = Scope(Input(index), pascal(function))
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
        Scope(Output(index), stem.semantic <> "Result"),
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
      )
    }
    Ok(Nil) -> {
      let required =
        list.filter(members, fn(m) { m.field.presence == schema.Required })
      let optional =
        list.filter(members, fn(m) { m.field.presence == schema.OptionalField })
      let options_type =
        "McpT"
        <> int.to_string(stem.direction.tool)
        <> "Options"
        <> semantic_name(stem.semantic)
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

// Each subtree receives a fresh ordinal after its parent. Semantic path names
// help a reader, while ordinals prevent equal Pascal spellings from aliasing.
fn members(
  fields: List(schema.Field),
  stem: Scope,
  start: Int,
  digest: fn(String) -> String,
) -> #(List(Member), Int) {
  list.map_fold(fields, start, fn(counter, field) {
    let label = name.mangle_label(field.original, digest)
    let child =
      node(
        field.shape,
        Scope(..stem, semantic: stem.semantic <> pascal(label)),
        counter,
        digest,
      )
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
  Node(shape, type_name, encode, decoder, [], counter + 1)
}

// A named two-variant boolean puts wire meaning at each call site instead of
// making the caller remember the polarity of a naked Bool parameter.
fn boolean_node(shape: schema.Shape, stem: Scope, counter: Int) -> Node {
  let identifier = node_identifier(stem, counter)
  let enabled =
    node_prefix(stem.direction, counter)
    <> "V0Enabled"
    <> semantic_name(stem.semantic)
  let disabled =
    node_prefix(stem.direction, counter)
    <> "V1Disabled"
    <> semantic_name(stem.semantic)
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
  Node(shape, identifier, encode, decoder, [definition], counter + 1)
}

// Enum labels receive the same digest discipline as tool and field names,
// plus a variant ordinal for different literals with the same sanitized name.
fn enum_variants(
  values: List(String),
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> List(#(String, String)) {
  list.index_map(values, fn(value, index) {
    #(
      value,
      node_prefix(stem.direction, counter)
        <> "V"
        <> int.to_string(index)
        <> semantic_name(stem.semantic <> pascal(name.mangle(value, digest))),
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
  Node(shape, identifier, encode, decoder, [definition], counter + 1)
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
      Scope(..stem, semantic: stem.semantic <> "Item"),
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
  Node(shape, type_name, encode, decoder, child.definitions, child.next)
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
      let fields =
        list.map(members, fn(m) {
          case m.field.presence {
            schema.Required ->
              "[#("
              <> codegen.lit(m.field.original)
              <> ", "
              <> encoded(m.node, "\u{1}." <> m.label)
              <> ")]"
            schema.OptionalField ->
              "codec.optional("
              <> codegen.lit(m.field.original)
              <> ", \u{1}."
              <> m.label
              <> ", "
              <> encoder_function(m.node, "item")
              <> ")"
          }
        })
      let encode =
        "report.object(list.flatten([" <> string.join(fields, ", ") <> "]))"
      let openness = case openness {
        schema.Open -> "codec.AllowAdditional"
        schema.Closed -> "codec.RejectAdditional"
      }
      let decoder =
        "codec.object(["
        <> string.join(
          list.map(members, fn(m) { codegen.lit(m.field.original) }),
          ", ",
        )
        <> "], "
        <> openness
        <> ", { "
        <> string.concat(
          list.map(members, fn(m) {
            let field_fn = case m.field.presence {
              schema.Required -> "field"
              schema.OptionalField -> "optional_field"
            }
            "use "
            <> m.label
            <> " <- codec."
            <> field_fn
            <> "("
            <> codegen.lit(m.field.original)
            <> ", "
            <> m.node.decoder
            <> ")\n "
          }),
        )
        <> "codec.success("
        <> constructor(
          identifier,
          list.map(members, fn(m) { m.label <> ": " <> m.label }),
        )
        <> ") })"
      Node(
        schema.Record(
          list.map(members, fn(m) {
            schema.Field(..m.field, shape: m.node.kind)
          }),
          case openness {
            "codec.AllowAdditional" -> schema.Open
            _ -> schema.Closed
          },
        ),
        identifier,
        encode,
        decoder,
        list.append(list.flat_map(members, fn(m) { m.node.definitions }), [
          record_definition(identifier, members),
        ]),
        next,
      )
    }
  }
}

fn record_definition(identifier: String, members: List(Member)) -> String {
  let head =
    "/// Named wire properties; optional fields retain absence separately from null.\npub type "
    <> identifier
    <> " {\n  /// Construct this wire record.\n  "
    <> identifier
  case members {
    [] -> head <> "\n}"
    _ ->
      head
      <> "(\n"
      <> string.join(
        list.map(members, fn(m) {
          let type_name = case m.field.presence {
            schema.Required -> m.node.type_name
            schema.OptionalField -> "Option(" <> m.node.type_name <> ")"
          }
          "    /// "
          <> codegen.clean(m.field.original, 100)
          <> " wire property.\n    "
          <> m.label
          <> ": "
          <> type_name
          <> ","
        }),
        "\n",
      )
      <> "\n  )\n}"
  }
}

// Planning proved the branches structurally disjoint. The trusted one_of
// combinator still requires exactly one successful decoder at the wire edge.
fn union_node(
  branches: List(schema.Shape),
  stem: Scope,
  counter: Int,
  digest: fn(String) -> String,
) -> Node {
  let identifier = node_identifier(stem, counter)
  let #(next, children) =
    list.map_fold(branches, counter + 1, fn(counter, branch) {
      let child =
        node(
          branch,
          Scope(..stem, semantic: stem.semantic <> "Branch"),
          counter,
          digest,
        )
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
        node_prefix(stem.direction, counter)
          <> "V"
          <> int.to_string(index)
          <> "Branch"
          <> semantic_name(stem.semantic),
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
  node_prefix(scope.direction, counter) <> semantic_name(scope.semantic)
}

// Semantic text is ASCII display only. The bounded trusted prefix owns
// identity, so clipping cannot collide and leaves every BEAM atom under 255
// bytes even when CamelCase is translated to Erlang snake_case.
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
