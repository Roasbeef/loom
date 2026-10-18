//// Tests for the prelude generator in `dev/gen_prelude.gleam` and the modules
//// beside it.
////
//// The alias and example cases are the ones the Python generator's tests
//// covered. The wrapping and decoding cases pin behaviour that a port could
//// change without anyone noticing until the committed artifact moved.

import gen_prelude
import gen_prelude/interface.{
  type Module, Constant, FunctionDeclaration, Module, Named, Parameter, Tuple,
  TypeAlias, TypeDeclaration, Variable,
}
import gen_prelude/wrap
import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import gleam/string

// ------------------------------------------------------------------ fixtures

/// `core/ids.EntryId`, the type two capabilities both alias.
fn identity() -> interface.Type {
  Named(module: "core/ids", name: "EntryId", parameters: [])
}

/// `gleam.Nil`.
fn nil() -> interface.Type {
  Named(module: "gleam", name: "Nil", parameters: [])
}

/// A module with nothing public.
fn empty_module() -> Module {
  Module(
    documentation: "",
    type_aliases: dict.new(),
    types: dict.new(),
    constants: dict.new(),
    functions: dict.new(),
  )
}

/// A module that aliases `core/ids.EntryId` as `EntryId`.
fn aliasing_module() -> Module {
  Module(
    ..empty_module(),
    type_aliases: dict.from_list([
      #(
        "EntryId",
        TypeAlias(documentation: "", parameters: 0, alias: identity()),
      ),
    ]),
  )
}

/// Two capabilities that expose the same identity on their own seams.
fn two_aliasing_modules() -> dict.Dict(String, Module) {
  dict.from_list([
    #("cap/peer", aliasing_module()),
    #("cap/strand", aliasing_module()),
  ])
}

// ------------------------------------------------------------------- aliases

pub fn each_capability_uses_its_own_identity_alias_test() {
  let aliases = gen_prelude.build_alias_map(two_aliasing_modules())

  assert gen_prelude.render_type(identity(), "cap/peer", aliases) == "EntryId"
  assert gen_prelude.render_type(identity(), "cap/strand", aliases) == "EntryId"
}

pub fn alias_preference_does_not_depend_on_build_order_test() {
  let forwards = two_aliasing_modules()
  let backwards =
    dict.from_list([
      #("cap/strand", aliasing_module()),
      #("cap/peer", aliasing_module()),
    ])

  assert gen_prelude.build_alias_map(forwards)
    == gen_prelude.build_alias_map(backwards)
}

pub fn other_modules_keep_the_first_modules_qualified_alias_test() {
  let aliases = gen_prelude.build_alias_map(two_aliasing_modules())

  assert gen_prelude.render_type(identity(), "cap/workflow", aliases)
    == "peer.EntryId"
}

pub fn a_parameterised_alias_is_not_reversed_test() {
  let generic =
    Named(module: "core/ids", name: "Id", parameters: [Variable(id: 0)])
  let module =
    Module(
      ..empty_module(),
      type_aliases: dict.from_list([
        #("Id", TypeAlias(documentation: "", parameters: 1, alias: generic)),
      ]),
    )
  let aliases =
    gen_prelude.build_alias_map(dict.from_list([#("cap/x", module)]))

  assert gen_prelude.render_type(generic, "cap/y", aliases) == "ids.Id(a)"
}

// --------------------------------------------------------------------- types

pub fn types_render_as_a_program_would_write_them_test() {
  let none = gen_prelude.build_alias_map(dict.new())
  let function_type =
    interface.FunctionType(parameters: [Variable(id: 0)], return: nil())
  let pair = Tuple(elements: [nil(), Variable(id: 27)])

  assert gen_prelude.render_type(function_type, "cap/fs", none)
    == "fn(a) -> Nil"
  assert gen_prelude.render_type(pair, "cap/fs", none) == "#(Nil, b1)"
  assert gen_prelude.render_type(
      Named(module: "cap/net", name: "Socket", parameters: [nil()]),
      "cap/fs",
      none,
    )
    == "net.Socket(Nil)"
}

pub fn variables_past_z_gain_a_numeric_suffix_test() {
  assert gen_prelude.variable_name(0) == "a"
  assert gen_prelude.variable_name(25) == "z"
  assert gen_prelude.variable_name(26) == "a1"
}

// ------------------------------------------------------------------ examples

pub fn runnable_example_keeps_indentation_test() {
  let documentation =
    "Contract.\n\n## Examples\n\n```gleam\ncase value {\n  Ok(x) -> x\n}\n```"
  let rendered = string.join(gen_prelude.example_block(documentation, ""), "\n")

  assert string.contains(rendered, "///   Ok(x) -> x")
  assert !string.contains(rendered, "Contract.")
}

pub fn missing_example_adds_nothing_test() {
  assert gen_prelude.example_block("Contract.", "") == []
}

pub fn examples_extend_only_the_on_demand_surface_test() {
  let probe =
    FunctionDeclaration(
      documentation: "Contract.\n\n## Examples\n\n```gleam\nprobe.probe()\n```",
      parameters: [],
      return: nil(),
    )
  let module =
    Module(
      ..empty_module(),
      documentation: "A probe.",
      functions: dict.from_list([#("probe", probe)]),
    )
  let modules = dict.from_list([#("cap/probe", module)])
  let aliases = gen_prelude.build_alias_map(modules)
  let surface = gen_prelude.render_module("cap/probe", module, aliases, modules)

  assert string.contains(surface.full, "/// probe.probe()")
  assert !string.contains(surface.types, "probe.probe()")
  assert string.starts_with(surface.full, surface.types)
}

// ------------------------------------------------------------------- modules

pub fn a_module_renders_its_heading_purpose_and_declarations_test() {
  let module =
    Module(
      ..empty_module(),
      documentation: "`cap/x` — does a thing. It does it well.",
      constants: dict.from_list([
        #("limit", Constant(documentation: "The cap.", type_: nil())),
      ]),
      functions: dict.from_list([
        #(
          "go",
          FunctionDeclaration(
            documentation: "Goes.",
            parameters: [
              Parameter(label: Some("to"), type_: nil()),
              Parameter(label: None, type_: nil()),
            ],
            return: nil(),
          ),
        ),
      ]),
      types: dict.from_list([
        #(
          "Opaque",
          TypeDeclaration(documentation: "", parameters: 1, constructors: []),
        ),
      ]),
    )
  let modules = dict.from_list([#("cap/x", module)])
  let aliases = gen_prelude.build_alias_map(modules)
  let surface = gen_prelude.render_module("cap/x", module, aliases, modules)

  assert surface.types
    == "### cap/x\n`cap/x` — does a thing.\n\npub type Opaque(a)\n"
  assert surface.full
    == "### cap/x\n`cap/x` — does a thing.\n\npub type Opaque(a)\n"
    <> "/// The cap.\npub const limit: Nil\n"
    <> "/// Goes.\npub fn go(to: Nil, Nil) -> Nil\n"
}

pub fn an_alias_of_an_unreachable_type_renders_bare_test() {
  let module =
    Module(
      ..empty_module(),
      type_aliases: dict.from_list([
        #(
          "Value",
          TypeAlias(documentation: "", parameters: 0, alias: identity()),
        ),
      ]),
    )
  let modules = dict.from_list([#("cap/x", module)])
  let aliases = gen_prelude.build_alias_map(modules)
  let surface = gen_prelude.render_module("cap/x", module, aliases, modules)

  assert string.contains(surface.full, "pub type Value\n")
}

// ----------------------------------------------------------------- documentation

pub fn paragraphs_join_lines_and_split_on_blank_lines_test() {
  assert gen_prelude.paragraphs(" One\n two.\n\n Three.\n")
    == ["One two.", "Three."]
}

pub fn first_sentence_stops_at_a_period_before_whitespace_test() {
  assert gen_prelude.first_sentence("Reads v1.2 files. Writes them.")
    == "Reads v1.2 files."
  assert gen_prelude.first_sentence("No terminator") == "No terminator"
  assert gen_prelude.first_sentence("Ends here.") == "Ends here."
}

pub fn strings_are_escaped_for_a_gleam_literal_test() {
  assert gen_prelude.gleam_string("a\"b\\c\nd") == "\"a\\\"b\\\\c\nd\""
}

// ------------------------------------------------------------------ wrapping

pub fn wrapping_breaks_at_spaces_test() {
  assert wrap.wrap("one two three", 7) == ["one two", "three"]
}

pub fn wrapping_breaks_after_a_hyphen_between_letters_test() {
  assert wrap.wrap("a read-only value", 10) == ["a read-", "only value"]
}

pub fn wrapping_does_not_break_after_a_leading_hyphen_test() {
  assert wrap.wrap("see -flag now", 6) == ["see", "-flag", "now"]
}

pub fn wrapping_cuts_a_word_longer_than_the_line_test() {
  assert wrap.wrap("abcdefghij", 4) == ["abcd", "efgh", "ij"]
}

pub fn wrapping_prefers_a_hyphen_when_cutting_a_long_word_test() {
  // `12-34` is not a place `textwrap` breaks, since digits are not letters,
  // so the hyphen is found only when the word has to be cut.
  assert wrap.wrap("12-34abcdefghij", 6) == ["12-", "34abcd", "efghij"]
}

pub fn wrapping_drops_the_space_where_a_line_breaks_test() {
  assert wrap.wrap("aa  bb", 2) == ["aa", "bb"]
}

pub fn wrapping_an_empty_text_gives_no_lines_test() {
  assert wrap.wrap("", 10) == []
}

// ------------------------------------------------------------------ decoding

/// One module whose only function returns the given type JSON.
fn interface_json(return: String) -> String {
  "{\"modules\": {\"cap/x\": {\"documentation\": [\" Line one.\", \" Line two.\"],"
  <> "\"functions\": {\"f\": {\"documentation\": \" F.\\n\","
  <> "\"parameters\": [{\"label\": null, \"type\": "
  <> return
  <> "}], \"return\": "
  <> return
  <> "}}}}}"
}

pub fn a_well_formed_interface_decodes_test() {
  let nil_json =
    "{\"kind\": \"named\", \"name\": \"Nil\", \"package\": \"\", \"module\": \"gleam\", \"parameters\": []}"

  let assert Ok(modules) = interface.parse(interface_json(nil_json))
  let assert Ok(module) = dict.get(modules, "cap/x")
  let assert Ok(function) = dict.get(module.functions, "f")

  assert module.documentation == " Line one.\n Line two."
  assert function.parameters == [Parameter(label: None, type_: nil())]
  assert function.return == nil()
}

pub fn an_unknown_type_kind_is_a_decode_failure_test() {
  let unknown = "{\"kind\": \"hologram\"}"

  let assert Error(json.UnableToDecode(errors)) =
    interface.parse(interface_json(unknown))

  assert errors != []
  assert string.contains(
    interface.describe(json.UnableToDecode(errors)),
    "hologram",
  )
}

pub fn a_missing_modules_key_is_a_decode_failure_test() {
  let assert Error(json.UnableToDecode(_)) = interface.parse("{}")
}

pub fn text_that_is_not_json_is_a_parse_failure_test() {
  let assert Error(_) = interface.parse("not json")
}
