//// R15, state-machine types before the code that moves through them (issue #593, 5).
////
//// A reader opening a state-machine module needs the state space first: the
//// states, the messages and the effects are the vocabulary every function
//// below is written in. When the types sit after the first function, the
//// reader meets `Next(State, Msg)` in a signature and has to scroll to learn
//// what either is, and the code stops being readable top to bottom.
////
//// The rule is decidable on the AST alone, which is why it can be made to
//// gate. A module is a state machine when it defines a *step function*, one
//// whose name is in `step_names`. The *state-space types* are the module's own
//// custom types and aliases that the step function's signature names,
//// searched through type arguments, tuples and function types. Each of those
//// must begin before the module's first function; each that does not is a
//// finding at the type, naming the step function and the first function it
//// has to precede. Constants and every type the signature does not name may
//// sit anywhere, so a module is not forced to hoist its helper records.
////
//// Nothing here does I/O. The census that fixed the name table is recorded
//// on `step_names`.

import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lint/finding
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines}

/// The function names that make a module a state machine.
///
/// The table is data so a census can change it without touching the walk.
/// `update`, `step`, `transition` and `handle_message` are the names this
/// codebase gives a pure machine's transition function. `handle` is the
/// actor spelling (`handle(state, message) -> Next(State, Message)`): over the
/// whole tree it added twenty-two findings in eleven modules, and every one
/// named a real state space (`State`, `Phase`, `Message`, `Data`), so it stays.
/// Four more were measured and left out. `loop` and `reduce` added nothing,
/// and a name that finds nothing only invites false positives later. `apply`
/// added `client/jobs`, already caught by its `handle`, so it bought nothing
/// but a generic fold name. `next` added `provider/stream.StreamHandle`, an
/// iterator cursor and not a state machine. Add a name here only after a
/// census shows its findings are real state machines.
///
/// ## Examples
///
/// ```gleam
/// list.contains(state_first.step_names(), "handle")
/// // -> True
/// ```
pub fn step_names() -> List(String) {
  ["update", "step", "transition", "handle_message", "handle"]
}

/// Every finding this rule makes about one parsed module.
///
/// ## Examples
///
/// ```gleam
/// state_first.findings(module, code, lines, policy.default(), "tools/fs")
/// // -> []
/// ```
pub fn findings(
  module: glance.Module,
  code: String,
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  let _ = #(code, lines, policy, own_path)
  findings_named(module, step_names())
}

/// The same judgement with the step-function names supplied, which is what
/// lets a census try a candidate name before it is added to `step_names`.
///
/// ## Examples
///
/// ```gleam
/// state_first.findings_named(module, ["update"])
/// // -> []
/// ```
pub fn findings_named(module: glance.Module, names: List(String)) -> List(Raw) {
  let functions = list.map(module.functions, fn(def) { def.definition })
  let steps = list.filter(functions, fn(fun) { list.contains(names, fun.name) })
  let first = first_function(functions)

  // Each state-space type is reported once, against the earliest step
  // function whose signature names it, so a module with both `update` and
  // `step` is not charged twice for the same late `State`.
  list.flat_map(local_types(module), fn(local) {
    let #(name, start) = local
    case first, owning_step(steps, name) {
      Some(#(first_name, first_start)), Some(step) if start > first_start -> [
        late_type(name, start, step.name, first_name),
      ]
      _, _ -> []
    }
  })
}

/// The earliest step function whose signature names `type_name`. Source order
/// decides, so the finding's wording does not depend on how `glance` lists
/// definitions.
fn owning_step(
  steps: List(glance.Function),
  type_name: String,
) -> Option(glance.Function) {
  steps
  |> list.sort(fn(a, b) { int.compare(a.location.start, b.location.start) })
  |> list.find(fn(fun) { set.contains(signature_names(fun), type_name) })
  |> option.from_result
}

/// The name and start offset of the module's first function, the line every
/// state-space type has to precede.
fn first_function(functions: List(glance.Function)) -> Option(#(String, Int)) {
  functions
  |> list.map(fn(fun) { #(fun.name, fun.location.start) })
  |> list.sort(fn(a, b) { int.compare(a.1, b.1) })
  |> list.first
  |> option.from_result
}

/// Every custom type and alias the module defines, with where it begins.
fn local_types(module: glance.Module) -> List(#(String, Int)) {
  let customs =
    list.map(module.custom_types, fn(def) {
      #(def.definition.name, def.definition.location.start)
    })
  let aliases =
    list.map(module.type_aliases, fn(def) {
      #(def.definition.name, def.definition.location.start)
    })
  list.append(customs, aliases)
}

/// The unqualified type names a function's signature mentions: parameters and
/// return type, searched through arguments, tuples and function types. A
/// qualified name (`dict.Dict`) belongs to another module and never matches a
/// local definition.
fn signature_names(fun: glance.Function) -> Set(String) {
  let parameters =
    list.filter_map(fun.parameters, fn(parameter) {
      option.to_result(parameter.type_, Nil)
    })
  let annotated = case fun.return {
    Some(return) -> [return, ..parameters]
    None -> parameters
  }
  list.fold(annotated, set.new(), type_names)
}

/// Add every local-looking name in one annotation to `seen`.
fn type_names(seen: Set(String), annotation: glance.Type) -> Set(String) {
  case annotation {
    glance.NamedType(module: None, name:, parameters:, ..) ->
      list.fold(parameters, set.insert(seen, name), type_names)
    glance.NamedType(module: Some(_), parameters:, ..) ->
      list.fold(parameters, seen, type_names)
    glance.TupleType(elements:, ..) -> list.fold(elements, seen, type_names)
    glance.FunctionType(parameters:, return:, ..) ->
      list.fold([return, ..parameters], seen, type_names)
    glance.VariableType(..) -> seen
    glance.HoleType(..) -> seen
  }
}

/// The finding for one late type.
fn late_type(
  name: String,
  start: Int,
  step: String,
  first_function: String,
) -> Raw {
  Raw(
    rule: finding.StateFirst,
    offset: start,
    function: name,
    detail: "`"
      <> name
      <> "` is part of the signature of the step function `"
      <> step
      <> "` but is defined after `"
      <> first_function
      <> "`; move it above the first function so the state space precedes the code that moves through it",
  )
}
