//// Renders the capability prelude's public surface, per module, as Gleam.
////
//// Run from `packages/tools`, normally through `scripts/gen-prelude.sh`:
////
//// ```text
//// gleam run -m gen_prelude -- <package-interface.json> <body.gleam>
//// ```
////
//// The input is `gleam export package-interface` over `packages/cap`, which
//// is the compiler's own view of what it will accept, and so the only source
//// that cannot drift from what a submitted program is compiled against. The
//// output is the body of `src/tools/prelude.gleam`: one rendered block per
//// module, keyed by module name, for `tools/codemode` to filter through a
//// seam's allowlist and show to a model. The script around this module adds
//// the digest header and formats the file.
////
//// ## Why the interface arrives as a file
////
//// Gleam has no in-process way to ask the compiler for a package's
//// interface, so something must run `gleam export package-interface`. Doing
//// that from here would need a process spawn, which in Gleam means an
//// `@external`, and generators use none. The shell script already runs the
//// compiler and already owns the digests, so it exports the JSON and hands
//// this module a path. The module is then pure apart from reading and writing
//// two files.
////
//// ## Why this lives in `tools`
////
//// `tools` holds the artifact and already depends on `gleam_stdlib`,
//// `gleam_regexp` and `simplifile`. The generator adds `gleam_json` and
//// `argv` as dev-dependencies, which do not reach `tools` consumers. It
//// cannot live in `core`, `machine` or `prompt`, which hold no I/O and no
//// external, and it should not live in `cap`, whose sources are compiled
//// into every code-mode program.
////
//// ## Two renderings of the same modules
////
//// The two readers want different amounts of the surface. `surfaces` is the
//// whole public surface, which `fs_read` of `cap://<module>` reads out on
//// demand. `type_surfaces` is the same block cut after the `pub type`
//// declarations: the heading, the module's purpose line, and the types with
//// their docs. That is what the `code_mode` description carries. Each
//// `type_surfaces` entry is a character-for-character prefix of its
//// `surfaces` counterpart, so the block a model reads on demand extends the
//// block it was shown instead of restating it in different words.
////
//// The cut is where it is because of what the two cost. A description is the
//// byte prefix of the provider's cached region, paid on every request of
//// every strand for the life of the session, and function signatures are the
//// bulk of a module. A signature a program needs can be read when it is
//// needed, and the read lands in the conversation tail rather than the
//// prefix. A type is different: `proc.run` returns a `proc.Output`, and a
//// program that cannot name the `stdout` field cannot read the output it
//// just paid for. A model that skips the read and guesses a field name pays
//// a compile either way, so the declarations stay where they cannot be
//// missed.
////
//// Nothing here decides which modules a seam admits. This renders every
//// module the interface reports, `cap/runtime` included. The allowlist filter
//// lives in `tools/codemode`, where the seam offers are. Rendering the filter
//// here would put a security-relevant decision in a build script and leave
//// the tool description asserting a claim nothing checks.
////
//// ## What is rendered, and what was left out
////
//// The block for a module is Gleam-shaped source: `pub type` declarations
//// with their constructors, `pub const`, and `pub fn` signatures, each under
//// its `///` documentation. It is Gleam-shaped rather than a compact notation
//// because the reader's whole job is to write Gleam, and a bespoke notation
//// would need teaching in the same bytes it saved.
////
//// Three omissions keep the blocks focused on callable APIs:
////
//// - **Parameter names.** The interface carries a parameter's label and not
////   its name, because the label is all a caller may write. A labelled
////   parameter renders `label: Type` and an unlabelled one renders as its
////   bare type. Inventing names for the unlabelled ones would read as labels
////   and teach a call the compiler rejects.
//// - **Headings in type documentation.** Function examples remain verbatim in
////   the on-demand surface, where callers need runnable syntax. They never
////   enter the shorter cached type surface.
//// - **All but the first sentence of a module's own doc.** A module doc runs
////   to the design rationale, which is written for someone changing the
////   prelude and not for someone calling it. The first sentence is the house
////   convention's purpose line and carries what a caller needs to choose
////   between modules.
////
//// ## How work moves through this module
////
//// 1. `main` reads the interface file and decodes it with
////    `gen_prelude/interface`.
//// 2. `build_alias_map` finds the type aliases that let a program name a type
////    from a module it cannot import.
//// 3. `render_module` renders each module twice, as one list of lines cut at
////    one point.
//// 4. `body` assembles the two constants and `main` writes them.
////
//// A failure panics. Gleam's standard library has no process exit and an
//// exit needs an `@external`, so the panic is how the script's exit status
//// becomes non-zero.

import argv
import gen_prelude/interface.{
  type Constructor, type Module, type Parameter, type Type, type TypeAlias,
  FunctionType, Named, Tuple, Variable,
}
import gen_prelude/wrap
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The rendered lines wrap here. Narrow enough to read as source, wide enough
/// that wrapping does not itself become a line of tokens per line.
const width = 74

/// Type variable names, in the order the compiler's numbers map to them.
const variable_letters = "abcdefghijklmnopqrstuvwxyz"

/// A type some module declares as an alias, and so can name.
pub type Alias {
  Alias(
    /// The module that declares the alias.
    module: String,
    /// The alias's name there.
    name: String,
  )
}

/// Which alias names a foreign type, for each module that might ask.
pub type AliasMap {
  AliasMap(
    /// The first alias found for a type, in module order, for modules that
    /// declare none of their own.
    first: Dict(#(String, String), Alias),
    /// A module's own alias for a type, keyed by type and by that module.
    own: Dict(#(String, String, String), Alias),
  )
}

/// One module rendered twice.
pub type Surface {
  Surface(
    /// The whole public surface.
    full: String,
    /// The heading, purpose line and `pub type` declarations: a prefix of
    /// `full`.
    types: String,
  )
}

/// Reads the package interface named by the first argument and writes the
/// rendered body to the second.
pub fn main() -> Nil {
  case argv.load().arguments {
    [interface_path, body_path] ->
      case run(interface_path, body_path) {
        Ok(Nil) -> Nil
        Error(message) -> panic as { "gen_prelude: " <> message }
      }

    arguments ->
      panic as {
        "gen_prelude: expected <package-interface.json> <body.gleam>, got "
        <> string.inspect(arguments)
      }
  }
}

/// Decodes the interface at `interface_path` and writes the body to
/// `body_path`.
fn run(interface_path: String, body_path: String) -> Result(Nil, String) {
  use text <- result.try(
    simplifile.read(interface_path)
    |> result.map_error(fn(reason) {
      "cannot read "
      <> interface_path
      <> ": "
      <> simplifile.describe_error(reason)
    }),
  )
  use modules <- result.try(
    interface.parse(text)
    |> result.map_error(fn(error) {
      interface_path <> ": " <> interface.describe(error)
    }),
  )

  simplifile.write(body_path, body(modules))
  |> result.map_error(fn(reason) {
    "cannot write " <> body_path <> ": " <> simplifile.describe_error(reason)
  })
}

// ---------------------------------------------------------------- assembly

/// The Gleam source of the two constants, `surfaces` then `type_surfaces`.
///
/// Both lists walk the modules in sorted order, so the artifact depends on
/// the interface's contents and not on how the compiler happened to order
/// them.
pub fn body(modules: Dict(String, Module)) -> String {
  let aliases = build_alias_map(modules)

  let surfaces =
    list.map(sorted_entries(modules), fn(entry) {
      #(entry.0, render_module(entry.0, entry.1, aliases, modules))
    })

  surfaces_doc
  <> "pub const surfaces: List(#(String, String)) = [\n"
  <> entries(surfaces, fn(surface) { surface.full })
  <> "\n]\n\n"
  <> type_surfaces_doc
  <> "pub const type_surfaces: List(#(String, String)) = [\n"
  <> entries(surfaces, fn(surface) { surface.types })
  <> "\n]\n"
}

/// One `#("module", "text"),` line per module.
fn entries(
  surfaces: List(#(String, Surface)),
  choose: fn(Surface) -> String,
) -> String {
  surfaces
  |> list.map(fn(pair) {
    "  #("
    <> gleam_string(pair.0)
    <> ", "
    <> gleam_string(choose(pair.1))
    <> "),"
  })
  |> string.join("\n")
}

/// The documentation above `surfaces`.
const surfaces_doc =
  "/// Every module of the capability prelude, in the order the
/// compiler reports them, paired with its public surface rendered
/// for a model to read.
///
/// Unfiltered on purpose: `tools/codemode` selects from this list
/// through the seam's own `allowed_imports`, so the one place that
/// decides what a model is shown is the one place that already
/// knows what vetting will accept. `cap/runtime` is in here and is
/// on neither seam's allowlist; it must never reach a description.
///
/// This is the whole surface, which is what `cap://<module>` reads
/// out on demand. What the tool description carries is the shorter
/// `type_surfaces` below.
"

/// The documentation above `type_surfaces`.
const type_surfaces_doc =
  "/// The same modules in the same order, cut after their `pub type`
/// declarations: the heading, the module's purpose line, and the
/// types with their docs, and nothing else.
///
/// This is what the `code_mode` description renders. A description
/// is the byte prefix of the provider's cached region, paid on
/// every request of every strand, and the functions are the bulk of
/// a module's surface while the types are what a program cannot
/// work around: a signature can be read from `cap://<module>` when
/// it is wanted, but a field name guessed wrong is a compile the
/// model pays for either way.
///
/// Each entry is a prefix of its `surfaces` counterpart, so the
/// block a model reads on demand extends the block it was shown
/// rather than restating it differently.
"

/// Text as a Gleam string literal, newlines and all.
///
/// Gleam string literals carry literal newlines, so the artifact stays
/// readable as the text it is rather than as one escaped line. Only the
/// backslash and the double quote need escaping.
///
/// ## Examples
///
/// ```gleam
/// assert gen_prelude.gleam_string("a\"b\\") == "\"a\\\"b\\\\\""
/// ```
pub fn gleam_string(text: String) -> String {
  let escaped =
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")

  "\"" <> escaped <> "\""
}

/// A dictionary's entries in key order, which is codepoint order for UTF-8.
///
/// A `Dict` has no order of its own. Sorting here is what makes the output
/// depend on the interface's contents and not on how it was built.
fn sorted_entries(values: Dict(String, a)) -> List(#(String, a)) {
  values
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

// ----------------------------------------------------------------- aliases

/// Finds, for each foreign type, the alias a program can use to name it.
///
/// `cap/report` aliases `core/msgpack.MsgPackValue` as `Value` precisely so
/// that a program can name the type without importing a module the allowlist
/// refuses. The interface expands aliases in signatures, so a literal
/// rendering would print `MsgPackValue`, a name that resolves nowhere a
/// program can reach. Reversing the aliases the prelude declares puts the
/// nameable name back, and derives it from the prelude rather than
/// hardcoding the one case that exists today.
///
/// Only an alias of a bare, unparameterised named type is reversible.
/// Several modules may alias the same type, as `cap/peer` and `cap/strand`
/// both alias `EntryId`. Each module then prefers its own alias, and every
/// other module takes the first alias in module order.
pub fn build_alias_map(modules: Dict(String, Module)) -> AliasMap {
  let empty = AliasMap(first: dict.new(), own: dict.new())

  sorted_entries(modules)
  |> list.fold(empty, fn(map, entry) {
    let #(module_name, module) = entry

    sorted_entries(module.type_aliases)
    |> list.fold(map, fn(map, alias_entry) {
      add_alias(map, module_name, alias_entry.0, alias_entry.1)
    })
  })
}

/// Records one alias, if it names a bare type.
fn add_alias(
  map: AliasMap,
  module: String,
  alias_name: String,
  alias: TypeAlias,
) -> AliasMap {
  case alias.alias {
    Named(module: target_module, name: target_name, parameters: []) -> {
      let here = Alias(module, alias_name)

      AliasMap(
        first: insert_if_absent(map.first, #(target_module, target_name), here),
        own: dict.insert(map.own, #(target_module, target_name, module), here),
      )
    }

    Named(..) | Variable(..) | FunctionType(..) | Tuple(..) -> map
  }
}

/// Inserts a key only when it has no value yet, so the first writer wins.
fn insert_if_absent(values: Dict(k, v), key: k, value: v) -> Dict(k, v) {
  case dict.has_key(values, key) {
    True -> values
    False -> dict.insert(values, key, value)
  }
}

/// How a program that imported module `here` writes a type's name.
///
/// A type from `here` or from the Gleam prelude is its bare name. A type that
/// some module aliases is written through that alias, qualified unless the
/// alias is `here`'s own. Anything else is qualified by the last segment of
/// its module, which is how an import is named: `cap/fs` is `fs`.
///
/// ## Examples
///
/// ```gleam
/// assert gen_prelude.qualify("cap/fs", "Entry", "cap/net", empty_aliases)
///   == "fs.Entry"
/// ```
pub fn qualify(
  module: String,
  name: String,
  here: String,
  aliases: AliasMap,
) -> String {
  case module == here || module == "gleam" {
    True -> name
    False ->
      case find_alias(aliases, module, name, here) {
        Some(Alias(module: alias_module, name: alias_name)) ->
          qualified(alias_module, alias_name, here)
        None -> qualified(module, name, here)
      }
  }
}

/// The alias for a type that `here` should use, preferring its own.
fn find_alias(
  aliases: AliasMap,
  module: String,
  name: String,
  here: String,
) -> Option(Alias) {
  case dict.get(aliases.own, #(module, name, here)) {
    Ok(alias) -> Some(alias)
    Error(Nil) ->
      case dict.get(aliases.first, #(module, name)) {
        Ok(alias) -> Some(alias)
        Error(Nil) -> None
      }
  }
}

/// A name as written from module `here`: bare in its own module, otherwise
/// prefixed with the last segment of its module.
fn qualified(module: String, name: String, here: String) -> String {
  case module == here {
    True -> name
    False -> last_segment(module) <> "." <> name
  }
}

/// `cap/fs` becomes `fs`.
fn last_segment(module: String) -> String {
  case list.last(string.split(module, "/")) {
    Ok(segment) -> segment
    Error(Nil) -> module
  }
}

// ------------------------------------------------------------------ types

/// A type variable's name. The interface numbers them; Gleam names them.
///
/// ## Examples
///
/// ```gleam
/// assert gen_prelude.variable_name(0) == "a"
/// assert gen_prelude.variable_name(27) == "b1"
/// ```
pub fn variable_name(index: Int) -> String {
  let letter = string.slice(variable_letters, index % 26, 1)

  case index < 26 {
    True -> letter
    False -> letter <> int.to_string(index / 26)
  }
}

/// A type as a program in module `here` would write it.
///
/// ## Examples
///
/// ```gleam
/// assert gen_prelude.render_type(Variable(0), "cap/fs", empty_aliases) == "a"
/// ```
pub fn render_type(node: Type, here: String, aliases: AliasMap) -> String {
  case node {
    Named(module:, name:, parameters: []) ->
      qualify(module, name, here, aliases)

    Named(module:, name:, parameters:) ->
      qualify(module, name, here, aliases)
      <> "("
      <> render_types(parameters, here, aliases)
      <> ")"

    Variable(id:) -> variable_name(id)

    FunctionType(parameters:, return:) ->
      "fn("
      <> render_types(parameters, here, aliases)
      <> ") -> "
      <> render_type(return, here, aliases)

    Tuple(elements:) -> "#(" <> render_types(elements, here, aliases) <> ")"
  }
}

/// Types separated by commas.
fn render_types(nodes: List(Type), here: String, aliases: AliasMap) -> String {
  nodes
  |> list.map(render_type(_, here, aliases))
  |> string.join(", ")
}

/// A parameter list, with a label before the parameters that have one.
fn parameter_list(
  parameters: List(Parameter),
  here: String,
  aliases: AliasMap,
) -> String {
  parameters
  |> list.map(fn(parameter) {
    let prefix = case parameter.label {
      Some(label) -> label <> ": "
      None -> ""
    }

    prefix <> render_type(parameter.type_, here, aliases)
  })
  |> string.join(", ")
}

/// `(a, b)` for a type with parameters, and nothing for one without.
fn type_parameters(count: Int) -> String {
  case count {
    0 -> ""
    _ -> {
      let names =
        list.repeat(Nil, count)
        |> list.index_map(fn(_, index) { variable_name(index) })

      "(" <> string.join(names, ", ") <> ")"
    }
  }
}

// ---------------------------------------------------------- documentation

/// A doc comment as whitespace-normalised paragraphs.
///
/// Lines are stripped and joined with a space, and a blank line ends the
/// paragraph.
///
/// ## Examples
///
/// ```gleam
/// assert gen_prelude.paragraphs(" One\n two.\n\n Three.") == ["One two.", "Three."]
/// ```
pub fn paragraphs(documentation: String) -> List(String) {
  let #(finished, current) =
    documentation
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.fold(#([], []), fn(state, line) {
      let #(finished, current) = state

      case line {
        "" -> close_paragraph(finished, current)
        _ -> #(finished, [line, ..current])
      }
    })

  let #(finished, _) = close_paragraph(finished, current)

  list.reverse(finished)
}

/// Ends the paragraph being collected, if there is one.
///
/// Both lists are held in reverse.
fn close_paragraph(
  finished: List(String),
  current: List(String),
) -> #(List(String), List(String)) {
  case current {
    [] -> #(finished, [])
    _ -> #([string.join(list.reverse(current), " "), ..finished], [])
  }
}

/// Every paragraph before the first markdown heading.
///
/// The heading is where a prelude doc comment stops addressing its caller and
/// starts addressing its maintainer: `## Examples` and the doctest beneath it,
/// in every case in the prelude today.
fn prose(documentation: String) -> List(String) {
  documentation
  |> paragraphs
  |> list.take_while(fn(paragraph) { !string.starts_with(paragraph, "#") })
}

/// The `## Examples` section of a doc comment, verbatim, as `///` lines.
///
/// Runnable examples keep their indentation. A doc without that heading adds
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert gen_prelude.example_block("Contract.", "") == []
/// ```
pub fn example_block(documentation: String, indent: String) -> List(String) {
  let lines = string.split(documentation, "\n")
  let from_heading =
    list.drop_while(lines, fn(line) { string.trim(line) != "## Examples" })

  case from_heading {
    [] -> []
    _ -> [
      indent <> "///",
      ..list.map(from_heading, fn(line) {
        case line {
          "" -> indent <> "///"
          _ -> indent <> "/// " <> line
        }
      })
    ]
  }
}

/// A doc comment's prose as wrapped `///` lines, paragraphs separated by an
/// empty `///`.
fn doc_block(documentation: String, indent: String) -> List(String) {
  let line_width = width - string.length(indent) - 4

  documentation
  |> prose
  |> list.index_map(fn(paragraph, index) {
    let separator = case index {
      0 -> []
      _ -> [indent <> "///"]
    }

    list.append(
      separator,
      list.map(wrap.wrap(paragraph, line_width), fn(line) {
        indent <> "/// " <> line
      }),
    )
  })
  |> list.flatten
}

/// Everything up to the first sentence-ending period.
///
/// The prelude's module docs all open `` `cap/x` — purpose.``, so this cut is
/// the house convention read back rather than a guess at where prose stops
/// being useful. A sentence ends at a period followed by whitespace or by the
/// end of the text.
///
/// ## Examples
///
/// ```gleam
/// assert gen_prelude.first_sentence("Reads files. Writes them.") == "Reads files."
/// ```
pub fn first_sentence(text: String) -> String {
  text
  |> string.to_graphemes
  |> take_sentence([])
  |> string.concat
}

/// Collects characters through the first period that ends a sentence.
///
/// The characters taken are held in reverse.
fn take_sentence(
  characters: List(String),
  taken: List(String),
) -> List(String) {
  case characters {
    [] -> list.reverse(taken)

    [".", ..rest] ->
      case starts_blank(rest) {
        True -> list.reverse([".", ..taken])
        False -> take_sentence(rest, [".", ..taken])
      }

    [character, ..rest] -> take_sentence(rest, [character, ..taken])
  }
}

/// Whether the text is empty or begins with whitespace.
fn starts_blank(characters: List(String)) -> Bool {
  case characters {
    [] -> True
    [next, ..] -> string.trim(next) == ""
  }
}

// ---------------------------------------------------------------- modules

/// One module rendered twice: the whole surface and its types alone.
///
/// The two renderings are the same lines cut at one point, not two passes.
/// `header` is the heading and the purpose line, `types` the `pub type`
/// declarations, and `rest` the constants and functions. The description pastes
/// header and types, and the `cap://` scheme reads out all three, so the block
/// a model reads on demand is a superset of the block it was shown, character
/// for character, rather than a second rendering that can disagree with the
/// first.
pub fn render_module(
  name: String,
  module: Module,
  aliases: AliasMap,
  all_modules: Dict(String, Module),
) -> Surface {
  let header = render_header(name, module)
  let types =
    list.append(
      render_aliases(name, module, aliases, all_modules),
      render_types_of(name, module, aliases),
    )
  let rest =
    list.append(
      render_constants(name, module, aliases),
      render_functions(name, module, aliases),
    )

  Surface(
    full: joined(list.flatten([header, types, rest])),
    types: joined(list.append(header, types)),
  )
}

/// Lines joined by newlines, trailing whitespace dropped, one newline added.
fn joined(lines: List(String)) -> String {
  string.trim_end(string.join(lines, "\n")) <> "\n"
}

/// The heading and the purpose line, then a blank line.
fn render_header(name: String, module: Module) -> List(String) {
  let purpose = case paragraphs(module.documentation) {
    [] -> []
    [summary, ..] -> wrap.wrap(first_sentence(summary), width)
  }

  list.flatten([["### " <> name], purpose, [""]])
}

/// The module's type aliases, in name order.
fn render_aliases(
  here: String,
  module: Module,
  aliases: AliasMap,
  all_modules: Dict(String, Module),
) -> List(String) {
  sorted_entries(module.type_aliases)
  |> list.flat_map(fn(entry) {
    let #(name, alias) = entry
    let head = "pub type " <> name <> type_parameters(alias.parameters)

    list.append(doc_block(alias.documentation, ""), [
      render_alias_line(head, alias, here, aliases, all_modules),
    ])
  })
}

/// One alias declaration.
///
/// A re-export of a type from outside the prelude has no right-hand side
/// worth printing: `cap/report.Value` aliases `core/msgpack.MsgPackValue`, and
/// a program cannot import `core/msgpack`, so `= MsgPackValue` would name
/// something that resolves nowhere it can reach. The reverse-alias map has
/// already put `Value` into every signature that mentions the type. The alias
/// therefore renders as a bare name, which is the caller's actual situation:
/// the type is reached only through the module's own functions.
fn render_alias_line(
  head: String,
  alias: TypeAlias,
  here: String,
  aliases: AliasMap,
  all_modules: Dict(String, Module),
) -> String {
  case reachable(alias.alias, all_modules) {
    True -> head <> " = " <> render_type(alias.alias, here, aliases)
    False -> head
  }
}

/// Whether a program can name the alias's target: anything but a named type
/// from outside the prelude.
fn reachable(target: Type, all_modules: Dict(String, Module)) -> Bool {
  case target {
    Named(module:, ..) -> module == "gleam" || dict.has_key(all_modules, module)
    Variable(..) | FunctionType(..) | Tuple(..) -> True
  }
}

/// The module's custom types, in name order.
fn render_types_of(
  here: String,
  module: Module,
  aliases: AliasMap,
) -> List(String) {
  sorted_entries(module.types)
  |> list.flat_map(fn(entry) {
    let #(name, declaration) = entry
    let head = "pub type " <> name <> type_parameters(declaration.parameters)

    list.append(
      doc_block(declaration.documentation, ""),
      render_constructors(head, declaration.constructors, here, aliases),
    )
  })
}

/// A type's declaration line, with its constructors in a block.
///
/// No constructors means opaque or external: the caller sees the name and
/// reaches the type only through the module's own functions, which is exactly
/// what an empty body says.
fn render_constructors(
  head: String,
  constructors: List(Constructor),
  here: String,
  aliases: AliasMap,
) -> List(String) {
  case constructors {
    [] -> [head]
    _ ->
      list.flatten([
        [head <> " {"],
        list.flat_map(constructors, render_constructor(_, here, aliases)),
        ["}"],
      ])
  }
}

/// One constructor under its documentation.
fn render_constructor(
  constructor: Constructor,
  here: String,
  aliases: AliasMap,
) -> List(String) {
  let suffix = case constructor.parameters {
    [] -> ""
    parameters -> "(" <> parameter_list(parameters, here, aliases) <> ")"
  }

  list.append(doc_block(constructor.documentation, "  "), [
    "  " <> constructor.name <> suffix,
  ])
}

/// The module's constants, in name order.
fn render_constants(
  here: String,
  module: Module,
  aliases: AliasMap,
) -> List(String) {
  sorted_entries(module.constants)
  |> list.flat_map(fn(entry) {
    let #(name, constant) = entry

    list.append(doc_block(constant.documentation, ""), [
      "pub const " <> name <> ": " <> render_type(constant.type_, here, aliases),
    ])
  })
}

/// The module's functions, in name order, each with its examples.
fn render_functions(
  here: String,
  module: Module,
  aliases: AliasMap,
) -> List(String) {
  sorted_entries(module.functions)
  |> list.flat_map(fn(entry) {
    let #(name, function) = entry

    list.flatten([
      doc_block(function.documentation, ""),
      example_block(function.documentation, ""),
      [
        "pub fn "
        <> name
        <> "("
        <> parameter_list(function.parameters, here, aliases)
        <> ") -> "
        <> render_type(function.return, here, aliases),
      ],
    ])
  })
}
