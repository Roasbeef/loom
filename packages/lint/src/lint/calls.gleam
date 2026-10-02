//// The in-module call graph: which functions of a module mention which.
////
//// Two rules need the same question answered. R8 (`lone-caller-arity`)
//// asks whether a long signature has exactly one caller; R17 and R18
//// (`flow-order`, `unnamed-helper`, issue #593) ask where those callers are
//// defined and how many there are. One walker answers all three so that
//// "caller" means the same thing in every census.
////
//// A caller is another function in this module whose body mentions the
//// name as a variable. That over-counts, because a local that shadows a
//// function's name reads as a call, and so it under-reports every rule
//// built on a lone caller. Recursion is not a caller: a function that
//// calls itself and is called once is the same shape as one that does not.
////
//// Known blind spot: a module `const` that mentions a function (a table of
//// function references, say) is not a caller, because the walk covers
//// function bodies only. A helper reached solely through a constant
//// therefore reads as having no caller.

import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// A private function that something else in its module calls, with the
/// functions that call it. Public functions are entry points and never
/// appear: nothing about where they sit is a question of call flow.
pub type Helper {
  Helper(
    /// The private function itself.
    function: glance.Function,
    /// Every other function of the module that mentions it, in definition
    /// order. Never empty.
    callers: List(glance.Function),
  )
}

/// The private functions of this module that have at least one caller, in
/// definition order.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(module) =
///   glance.module("pub fn a() { b() }\nfn b() { 1 }\nfn c() { 2 }\n")
/// let names = list.map(calls.private_helpers(module), fn(h) { h.function.name })
/// assert names == ["b"]
/// ```
pub fn private_helpers(module: glance.Module) -> List(Helper) {
  module.functions
  |> list.sort(fn(left, right) {
    int.compare(left.definition.location.start, right.definition.location.start)
  })
  |> list.filter_map(fn(definition) {
    let function = definition.definition
    case function.publicity, callers_of(module, function.name) {
      glance.Private, [_, ..] as callers ->
        Ok(Helper(function:, callers: list.map(callers, fn(c) { c.definition })))
      _, _ -> Error(Nil)
    }
  })
}

/// The functions of this module, other than `name` itself, whose body
/// mentions `name`, in definition order. Sorted by position rather than
/// trusting `module.functions`, which `glance` hands back newest-first.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(module) = glance.module("fn a() { b() }\nfn b() { 1 }\n")
/// let names = list.map(calls.callers_of(module, "b"), fn(f) { f.definition.name })
/// assert names == ["a"]
/// ```
pub fn callers_of(
  module: glance.Module,
  name: String,
) -> List(glance.Definition(glance.Function)) {
  module.functions
  |> list.filter(fn(other) {
    other.definition.name != name && mentions_in(other.definition.body, name)
  })
  |> list.sort(fn(left, right) {
    int.compare(left.definition.location.start, right.definition.location.start)
  })
}

/// Does `name` appear as a variable anywhere in this expression?
///
/// Over-approximates in the safe direction: a shadowing binding inside a
/// closure counts as a mention, which drops a row rather than inventing
/// one. Exhaustive over `glance.Expression` for the reason everything in
/// this file is — a new syntax node must fail to compile here rather than
/// quietly stop being searched.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(module) = glance.module("fn a() { b() }")
/// let assert [glance.Definition(definition: a, ..)] = module.functions
/// assert calls.mentions_in(a.body, "b")
/// ```
pub fn mentions(value: glance.Expression, name: String) -> Bool {
  case value {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> False
    glance.Variable(name: found, ..) -> found == name
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      mentions(inner, name)
    glance.Block(statements: body, ..) -> mentions_in(body, name)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      mentions_optional(message, name)
    glance.Echo(expression: inner, message:, ..) ->
      mentions_optional(inner, name) || mentions_optional(message, name)
    glance.Tuple(elements:, ..) ->
      list.any(elements, fn(element) { mentions(element, name) })
    glance.List(elements:, rest:, ..) ->
      list.any(elements, fn(element) { mentions(element, name) })
      || mentions_optional(rest, name)
    glance.Fn(body:, ..) -> mentions_in(body, name)
    glance.RecordUpdate(record:, fields:, ..) ->
      mentions(record, name)
      || list.any(fields, fn(field) { mentions_optional(field.item, name) })
    glance.FieldAccess(container:, ..) -> mentions(container, name)
    glance.Call(function:, arguments:, ..) ->
      mentions(function, name) || mentions_fields(arguments, name)
    glance.TupleIndex(tuple:, ..) -> mentions(tuple, name)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      mentions(function, name)
      || mentions_fields(arguments_before, name)
      || mentions_fields(arguments_after, name)
    glance.BitString(segments:, ..) ->
      list.any(segments, fn(segment) { mentions(segment.0, name) })
    glance.Case(subjects:, clauses:, ..) ->
      list.any(subjects, fn(subject) { mentions(subject, name) })
      || list.any(clauses, fn(clause) { mentions(clause.body, name) })
    glance.BinaryOperator(left:, right:, ..) ->
      mentions(left, name) || mentions(right, name)
  }
}

/// Does `name` appear as a variable anywhere in these statements?
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(module) = glance.module("fn a() { 1 }")
/// let assert [glance.Definition(definition: a, ..)] = module.functions
/// assert !calls.mentions_in(a.body, "b")
/// ```
pub fn mentions_in(body: List(glance.Statement), name: String) -> Bool {
  list.any(body, fn(statement) {
    case statement {
      glance.Use(function:, ..) -> mentions(function, name)
      glance.Expression(value) -> mentions(value, name)
      glance.Assert(expression: value, message:, ..) ->
        mentions(value, name) || mentions_optional(message, name)
      glance.Assignment(value:, ..) -> mentions(value, name)
    }
  })
}

fn mentions_optional(value: Option(glance.Expression), name: String) -> Bool {
  case value {
    Some(inner) -> mentions(inner, name)
    None -> False
  }
}

fn mentions_fields(
  arguments: List(glance.Field(glance.Expression)),
  name: String,
) -> Bool {
  list.any(arguments, fn(field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        mentions(item, name)

      // `f(key:)` is a use of the variable `key`.
      glance.ShorthandField(label:, ..) -> label == name
    }
  })
}
