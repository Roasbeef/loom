//// R19, a prerequisite skip printed to stdout from a test (test sources only).
////
//// A suite that cannot run its prerequisites prints `SKIP <name>: <reason>`
//// and returns, and `.github/scripts/skip_census.sh` greps the run's log for
//// that line so a skipped suite turns CI red instead of reading as a pass.
//// Under EUnit the log only contains what reaches stderr: EUnit captures a
//// passing test's stdout and discards it, even with verbose progress. A skip
//// printed with `io.println` therefore vanishes exactly when the suite is
//// green, which is the one case the census exists to catch. The sanctioned
//// emitter is `io.println_error`, which writes the same line to stderr.
////
//// The rule reads the parsed module rather than the text, which is what the
//// regular expression it replaces had to approximate. It reports a call to
//// `io.println` or `io.print` — through whatever alias or unqualified import
//// the file gave `gleam/io` — whose first argument is a string literal
//// beginning `SKIP` as a word, or a concatenation whose leftmost operand is
//// one (`"SKIP " <> name <> ": " <> reason`), or the same literal piped into
//// either function. A call quoted inside a string, a comment, or a different
//// module's `println` is not a call to this one and is never reported.
////
//// The rule is scoped to test sources by the caller: `lint/cli` runs it on
//// files under `test/` and nowhere else, because `src/` has no skip
//// convention and a library that prints `SKIP` is saying something else.

import glance
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lint/finding
import lint/scan.{type Raw, Raw}

/// How this file can spell a call to `gleam/io`'s stdout writers: the
/// qualifiers it was imported under, and the local names of any unqualified
/// `println` or `print`.
type Emitters {
  Emitters(qualifiers: List(String), bare: List(String))
}

/// Every stdout SKIP emitter in one parsed module.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(module) =
///   glance.module("import gleam/io\npub fn f() { io.println(\"SKIP x: y\") }")
/// let assert [found] = skip_stdout.findings(module)
/// assert found.function == "f"
/// ```
pub fn findings(module: glance.Module) -> List(Raw) {
  let emitters = emitters_of(module)
  module.functions
  |> list.flat_map(fn(definition) {
    let function = definition.definition
    statements(function.body, emitters, function.name, [])
  })
}

/// The spellings of `io.println` and `io.print` this module's imports allow.
fn emitters_of(module: glance.Module) -> Emitters {
  let imports =
    module.imports
    |> list.map(fn(definition) { definition.definition })
    |> list.filter(fn(import_) { import_.module == "gleam/io" })
  Emitters(
    qualifiers: list.flat_map(imports, qualifier_of),
    bare: list.flat_map(imports, bare_of),
  )
}

/// The name a call is qualified with: the alias when there is one, the last
/// path segment otherwise, and nothing for a discarded alias.
fn qualifier_of(import_: glance.Import) -> List(String) {
  case import_.alias {
    Some(glance.Named(alias)) -> [alias]
    Some(glance.Discarded(_)) -> []
    None -> ["io"]
  }
}

/// The local names under which an unqualified `println` or `print` is in scope.
fn bare_of(import_: glance.Import) -> List(String) {
  import_.unqualified_values
  |> list.filter(fn(value) { is_stdout_writer(value.name) })
  |> list.map(fn(value) {
    case value.alias {
      Some(alias) -> alias
      None -> value.name
    }
  })
}

fn is_stdout_writer(name: String) -> Bool {
  name == "println" || name == "print"
}

/// Whether an expression names one of the stdout writers.
fn is_emitter(callee: glance.Expression, emitters: Emitters) -> Bool {
  case callee {
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) ->
      list.contains(emitters.qualifiers, qualifier) && is_stdout_writer(label)
    glance.Variable(name:, ..) -> list.contains(emitters.bare, name)
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.NegateInt(..)
    | glance.NegateBool(..)
    | glance.Block(..)
    | glance.Panic(..)
    | glance.Todo(..)
    | glance.Echo(..)
    | glance.Tuple(..)
    | glance.List(..)
    | glance.Fn(..)
    | glance.RecordUpdate(..)
    | glance.FieldAccess(..)
    | glance.Call(..)
    | glance.TupleIndex(..)
    | glance.FnCapture(..)
    | glance.BitString(..)
    | glance.Case(..)
    | glance.BinaryOperator(..) -> False
  }
}

/// Whether an expression is a string whose text begins with `SKIP` as a
/// word: the literal itself, or the leftmost operand of a `<>` chain.
fn leads_with_skip(value: glance.Expression) -> Bool {
  case value {
    glance.String(value: text, ..) -> is_skip_text(text)
    glance.BinaryOperator(name: glance.Concatenate, left:, ..) ->
      leads_with_skip(left)
    glance.BinaryOperator(..)
    | glance.Int(..)
    | glance.Float(..)
    | glance.Variable(..)
    | glance.NegateInt(..)
    | glance.NegateBool(..)
    | glance.Block(..)
    | glance.Panic(..)
    | glance.Todo(..)
    | glance.Echo(..)
    | glance.Tuple(..)
    | glance.List(..)
    | glance.Fn(..)
    | glance.RecordUpdate(..)
    | glance.FieldAccess(..)
    | glance.Call(..)
    | glance.TupleIndex(..)
    | glance.FnCapture(..)
    | glance.BitString(..)
    | glance.Case(..) -> False
  }
}

/// `SKIP` followed by whitespace or the end of the literal. `SKIPPED` and
/// `ordinary output mentioning SKIP` are prose, not the census's marker.
fn is_skip_text(text: String) -> Bool {
  case string.starts_with(text, "SKIP") {
    False -> False
    True ->
      case string.first(string.drop_start(text, 4)) {
        Error(Nil) -> True
        Ok(next) -> string.trim(next) == ""
      }
  }
}

fn finding_at(offset: Int, function: String) -> Raw {
  Raw(
    rule: finding.StdoutSkip,
    offset:,
    function:,
    detail: "a SKIP diagnostic printed to stdout is discarded by EUnit when "
      <> "the suite passes, so the skip census never sees it; print it with "
      <> "`io.println_error` so it reaches the log "
      <> "(.github/scripts/skip_census.sh)",
  )
}

// --- the walk ---------------------------------------------------------------

fn statements(
  body: List(glance.Statement),
  emitters: Emitters,
  function: String,
  acc: List(Raw),
) -> List(Raw) {
  list.fold(body, acc, fn(acc, statement) {
    case statement {
      glance.Use(function: value, ..) | glance.Expression(value) ->
        expression(value, emitters, function, acc)
      glance.Assert(expression: value, message:, ..) ->
        optional(
          message,
          emitters,
          function,
          expression(value, emitters, function, acc),
        )
      glance.Assignment(value:, ..) ->
        expression(value, emitters, function, acc)
    }
  })
}

fn expressions(
  values: List(glance.Expression),
  emitters: Emitters,
  function: String,
  acc: List(Raw),
) -> List(Raw) {
  list.fold(values, acc, fn(acc, value) {
    expression(value, emitters, function, acc)
  })
}

fn optional(
  value: option.Option(glance.Expression),
  emitters: Emitters,
  function: String,
  acc: List(Raw),
) -> List(Raw) {
  case value {
    Some(inner) -> expression(inner, emitters, function, acc)
    None -> acc
  }
}

fn fields(
  arguments: List(glance.Field(glance.Expression)),
  emitters: Emitters,
  function: String,
  acc: List(Raw),
) -> List(Raw) {
  list.fold(arguments, acc, fn(acc, field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        expression(item, emitters, function, acc)
      glance.ShorthandField(..) -> acc
    }
  })
}

fn expression(
  value: glance.Expression,
  emitters: Emitters,
  function: String,
  acc: List(Raw),
) -> List(Raw) {
  case value {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> acc
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      expression(inner, emitters, function, acc)
    glance.Block(statements: body, ..) ->
      statements(body, emitters, function, acc)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      optional(message, emitters, function, acc)
    glance.Echo(expression: inner, message:, ..) ->
      optional(
        message,
        emitters,
        function,
        optional(inner, emitters, function, acc),
      )
    glance.Tuple(elements:, ..) ->
      expressions(elements, emitters, function, acc)
    glance.List(elements:, rest:, ..) ->
      optional(
        rest,
        emitters,
        function,
        expressions(elements, emitters, function, acc),
      )
    glance.Fn(body:, ..) -> statements(body, emitters, function, acc)
    glance.RecordUpdate(record:, fields: updates, ..) ->
      list.fold(
        updates,
        expression(record, emitters, function, acc),
        fn(acc, update) { optional(update.item, emitters, function, acc) },
      )
    glance.FieldAccess(container:, ..) ->
      expression(container, emitters, function, acc)
    glance.TupleIndex(tuple:, ..) -> expression(tuple, emitters, function, acc)
    glance.Call(location:, function: callee, arguments:) ->
      fields(
        arguments,
        emitters,
        function,
        expression(
          callee,
          emitters,
          function,
          call_findings(location, callee, arguments, emitters, function, acc),
        ),
      )
    glance.FnCapture(function: callee, arguments_before:, arguments_after:, ..) ->
      fields(
        arguments_after,
        emitters,
        function,
        fields(
          arguments_before,
          emitters,
          function,
          expression(callee, emitters, function, acc),
        ),
      )
    glance.BitString(segments:, ..) ->
      list.fold(segments, acc, fn(acc, segment) {
        expression(segment.0, emitters, function, acc)
      })
    glance.Case(subjects:, clauses:, ..) ->
      list.fold(
        clauses,
        expressions(subjects, emitters, function, acc),
        fn(acc, clause) {
          expression(
            clause.body,
            emitters,
            function,
            optional(clause.guard, emitters, function, acc),
          )
        },
      )
    glance.BinaryOperator(name:, location:, left:, right:) ->
      expression(
        right,
        emitters,
        function,
        expression(
          left,
          emitters,
          function,
          pipe_findings(name, location, left, right, emitters, function, acc),
        ),
      )
  }
}

/// A call that writes a SKIP literal to stdout: the first argument is the
/// message whether or not it is labelled (`io.println(string: …)`).
fn call_findings(
  location: glance.Span,
  callee: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
  emitters: Emitters,
  function: String,
  acc: List(Raw),
) -> List(Raw) {
  case is_emitter(callee, emitters), arguments {
    True, [glance.LabelledField(item:, ..), ..]
    | True, [glance.UnlabelledField(item:), ..]
    ->
      case leads_with_skip(item) {
        True -> [finding_at(location.start, function), ..acc]
        False -> acc
      }
    _, _ -> acc
  }
}

/// `"SKIP …" |> io.println`: the literal arrives as the writer's argument.
fn pipe_findings(
  operator: glance.BinaryOperator,
  location: glance.Span,
  left: glance.Expression,
  right: glance.Expression,
  emitters: Emitters,
  function: String,
  acc: List(Raw),
) -> List(Raw) {
  case operator == glance.Pipe, is_emitter(right, emitters) {
    True, True ->
      case leads_with_skip(left) {
        True -> [finding_at(location.start, function), ..acc]
        False -> acc
      }
    _, _ -> acc
  }
}
