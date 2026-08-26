//// The AST walk: what each rule looks for.
////
//// One pass over a parsed module yields every violation, each carrying the
//// byte offset of the construct that caused it. `glance` attaches a span to
//// every expression and pattern, so a finding points at the guard, the arm
//// or the `panic` itself rather than at the function that contains it.
////
//// Nothing here does I/O and nothing here can fail. An expression the walker
//// does not model contributes no finding rather than an error, and every
//// `case` over a `glance` type is exhaustive so a new syntax node is a
//// compile error here rather than a silent gap.

import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lint/finding.{type Rule}
import lint/policy.{type Eager, type Policy}

/// One violation, located by byte offset. `lint` turns the offset into a
/// line; the walk has no idea what a line is.
pub type Raw {
  Raw(rule: Rule, offset: Int, function: String, detail: String)
}

/// Local names in scope: what a qualifier resolves to, and what an
/// unqualified value was imported from.
type Names {
  Names(
    qualifiers: Dict(String, String),
    values: Dict(String, #(String, String)),
  )
}

type Ctx {
  Ctx(names: Names, policy: Policy, function: String)
}

/// Every violation in a parsed module, in no particular order.
pub fn module(module: glance.Module, policy: Policy) -> List(Raw) {
  let names = names_of(module)
  list.flat_map(module.functions, fn(definition) {
    let function = definition.definition
    let ctx = Ctx(names:, policy:, function: function.name)
    list.reverse(statements(function.body, ctx, nesting(function, ctx)))
  })
}

/// R2, which is about the function rather than about anything inside it.
fn nesting(function: glance.Function, ctx: Ctx) -> List(Raw) {
  let depth = statements_depth(function.body)
  case depth > ctx.policy.nesting_threshold {
    False -> []
    True -> [
      Raw(
        rule: finding.NestingDepth,
        offset: function.location.start,
        function: function.name,
        detail: "`case` nests "
          <> int.to_string(depth)
          <> " deep (threshold "
          <> int.to_string(ctx.policy.nesting_threshold)
          <> "); measured on the AST, so a wrapped literal is not depth",
      ),
    ]
  }
}

// --- name resolution --------------------------------------------------------

fn names_of(module: glance.Module) -> Names {
  list.fold(module.imports, Names(dict.new(), dict.new()), fn(names, imported) {
    let import_ = imported.definition
    let qualifiers = case import_.alias {
      Some(glance.Named(alias)) ->
        dict.insert(names.qualifiers, alias, import_.module)
      Some(glance.Discarded(_)) -> names.qualifiers
      None ->
        dict.insert(
          names.qualifiers,
          last_segment(import_.module),
          import_.module,
        )
    }
    let values =
      list.fold(import_.unqualified_values, names.values, fn(values, value) {
        let local = case value.alias {
          Some(alias) -> alias
          None -> value.name
        }
        dict.insert(values, local, #(import_.module, value.name))
      })
    Names(qualifiers:, values:)
  })
}

fn last_segment(path: String) -> String {
  case list.reverse(string.split(path, "/")) {
    [last, ..] -> last
    [] -> path
  }
}

/// Resolve an expression that names a function to the module path and name
/// it refers to. Handles the qualified form (`bool.guard`, and any alias the
/// module was imported under) and the unqualified form.
fn resolve(
  names: Names,
  value: glance.Expression,
) -> Option(#(String, String)) {
  case value {
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) ->
      case dict.get(names.qualifiers, qualifier) {
        Ok(path) -> Some(#(path, label))
        Error(Nil) -> None
      }
    glance.Variable(name:, ..) ->
      case dict.get(names.values, name) {
        Ok(resolved) -> Some(resolved)
        Error(Nil) -> None
      }
    _ -> None
  }
}

fn eager_spec(path: String, name: String) -> Option(Eager) {
  list.fold(policy.eager_combinators(), None, fn(found, spec) {
    case found, spec.module == path && spec.function == name {
      None, True -> Some(spec)
      _, _ -> found
    }
  })
}

fn is_length(target: Option(#(String, String))) -> Bool {
  case target {
    Some(#(path, name)) ->
      path == policy.length_module && name == policy.length_function
    None -> False
  }
}

// --- the walk ---------------------------------------------------------------

fn statements(
  body: List(glance.Statement),
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  list.fold(body, acc, fn(acc, statement) { statement_(statement, ctx, acc) })
}

fn statement_(
  statement: glance.Statement,
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  case statement {
    glance.Use(function:, ..) -> expression(function, ctx, acc)
    glance.Expression(value) -> expression(value, ctx, acc)
    glance.Assert(expression: value, message:, ..) ->
      optional(message, ctx, expression(value, ctx, acc))
    glance.Assignment(kind:, value:, location:, ..) -> {
      let acc = case kind, ctx.policy.allow_panic {
        glance.LetAssert(..), False -> [
          Raw(
            rule: finding.PanicInSource,
            offset: location.start,
            function: ctx.function,
            detail: "`let assert` crashes the process when the value has "
              <> "another shape; outside tests a total match, or a decoder "
              <> "that returns an error, is the house rule",
          ),
          ..acc
        ]
        _, _ -> acc
      }
      expression(value, ctx, acc)
    }
  }
}

fn expressions(
  values: List(glance.Expression),
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  list.fold(values, acc, fn(acc, value) { expression(value, ctx, acc) })
}

fn expression(value: glance.Expression, ctx: Ctx, acc: List(Raw)) -> List(Raw) {
  case value {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> acc
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      expression(inner, ctx, acc)
    glance.Block(statements: body, ..) -> statements(body, ctx, acc)
    glance.Panic(message:, location:) ->
      optional(message, ctx, panic_finding(location, ctx, acc))
    glance.Todo(message:, ..) -> optional(message, ctx, acc)
    glance.Echo(expression: inner, message:, ..) ->
      optional(message, ctx, optional(inner, ctx, acc))
    glance.Tuple(elements:, ..) -> expressions(elements, ctx, acc)
    glance.List(elements:, rest:, ..) ->
      optional(rest, ctx, expressions(elements, ctx, acc))
    glance.Fn(body:, ..) -> statements(body, ctx, acc)
    glance.RecordUpdate(record:, fields:, ..) ->
      list.fold(fields, expression(record, ctx, acc), fn(acc, field) {
        optional(field.item, ctx, acc)
      })
    glance.FieldAccess(container:, ..) -> expression(container, ctx, acc)
    glance.Call(function:, arguments:, ..) ->
      call(function, arguments, False, ctx, acc)
    glance.TupleIndex(tuple:, ..) -> expression(tuple, ctx, acc)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      fields(
        arguments_after,
        ctx,
        fields(arguments_before, ctx, expression(function, ctx, acc)),
      )
    glance.BitString(segments:, ..) ->
      list.fold(segments, acc, fn(acc, segment) {
        expression(segment.0, ctx, acc)
      })
    glance.Case(subjects:, clauses:, ..) -> case_(subjects, clauses, ctx, acc)
    glance.BinaryOperator(name:, left:, right:, ..) ->
      binary(name, left, right, ctx, acc)
  }
}

fn panic_finding(location: glance.Span, ctx: Ctx, acc: List(Raw)) -> List(Raw) {
  case ctx.policy.allow_panic {
    True -> acc
    False -> [
      Raw(
        rule: finding.PanicInSource,
        offset: location.start,
        function: ctx.function,
        detail: "`panic` crashes the harness VM; outside tests a total "
          <> "function returns an error instead",
      ),
      ..acc
    ]
  }
}

fn optional(
  value: Option(glance.Expression),
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  case value {
    Some(inner) -> expression(inner, ctx, acc)
    None -> acc
  }
}

fn fields(
  arguments: List(glance.Field(glance.Expression)),
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  list.fold(arguments, acc, fn(acc, field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        expression(item, ctx, acc)
      // `f(value:)` — the argument is the variable of that name, nothing to
      // descend into.
      glance.ShorthandField(..) -> acc
    }
  })
}

// --- R1: the eager fallback -------------------------------------------------

fn call(
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
  piped: Bool,
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  let acc = case resolve(ctx.names, function) {
    Some(#(path, name)) ->
      case eager_spec(path, name) {
        Some(spec) -> eager(spec, function, arguments, piped, ctx, acc)
        None -> acc
      }
    None -> acc
  }
  fields(arguments, ctx, expression(function, ctx, acc))
}

fn eager(
  spec: Eager,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
  piped: Bool,
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  case eager_argument(spec, arguments, piped) {
    None -> acc
    Some(argument) ->
      case cheap(argument) {
        True -> acc
        False -> [
          Raw(
            rule: finding.EagerFallback,
            offset: span_of(function).start,
            function: ctx.function,
            detail: "`"
              <> last_segment(spec.module)
              <> "."
              <> spec.function
              <> "`'s `"
              <> spec.label
              <> ":` is "
              <> describe(argument)
              <> "; an eager argument is built on every call, taken or not, "
              <> "so use `"
              <> spec.lazy
              <> "`",
          ),
          ..acc
        ]
      }
  }
}

/// The argument this combinator evaluates whether it needs it or not: by
/// label when the call gives one, otherwise by position. A piped call is
/// written with its first argument to the left of `|>`, so its positions are
/// shifted by one.
fn eager_argument(
  spec: Eager,
  arguments: List(glance.Field(glance.Expression)),
  piped: Bool,
) -> Option(glance.Expression) {
  case labelled(arguments, spec.label) {
    Some(item) -> Some(item)
    None -> {
      let position = case piped {
        True -> spec.position - 1
        False -> spec.position
      }
      let positional =
        list.filter_map(arguments, fn(field) {
          case field {
            glance.UnlabelledField(item:) -> Ok(item)
            glance.LabelledField(..) | glance.ShorthandField(..) -> Error(Nil)
          }
        })
      case position >= 0 {
        False -> None
        True ->
          case list.drop(positional, position) {
            [item, ..] -> Some(item)
            [] -> None
          }
      }
    }
  }
}

fn labelled(
  arguments: List(glance.Field(glance.Expression)),
  wanted: String,
) -> Option(glance.Expression) {
  case arguments {
    [] -> None
    [glance.LabelledField(label:, item:, ..), ..rest] ->
      case label == wanted {
        True -> Some(item)
        False -> labelled(rest, wanted)
      }
    // `return:` given as shorthand is a bare variable: already cheap.
    [_, ..rest] -> labelled(rest, wanted)
  }
}

/// Is this a value the call would happily compute anyway?
///
/// Trivially cheap means a literal, a bare variable (which is also how a
/// nullary constructor is spelled), or a constructor applied only to
/// trivially cheap things. Reading a record field, indexing a tuple and
/// building a closure are O(1) and join them. Everything else — a call, a
/// `<>`, a pipeline, a block, a `case` — is work, and work in an eager
/// argument is work done on the path where the fallback is *not* taken.
///
/// The predicate is where this rule lives or dies. Too strict and every
/// guard in the tree flags; too loose and it misses `Error(fail(cursor,
/// "…"))`, the shape that made `core/json` quadratic.
pub fn cheap(value: glance.Expression) -> Bool {
  case value {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> True
    glance.Variable(..) -> True
    glance.Fn(..) | glance.FnCapture(..) -> True
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      cheap(inner)
    glance.TupleIndex(tuple:, ..) -> cheap(tuple)
    glance.FieldAccess(container:, ..) -> cheap(container)
    glance.Tuple(elements:, ..) -> list.all(elements, cheap)
    glance.List(elements:, rest:, ..) ->
      list.all(elements, cheap) && cheap_optional(rest)
    glance.RecordUpdate(record:, fields:, ..) ->
      cheap(record)
      && list.all(fields, fn(field) { cheap_optional(field.item) })
    glance.Call(function:, arguments:, ..) ->
      constructor_reference(function) && list.all(arguments, cheap_field)
    // Arithmetic, comparison and boolean operators over cheap operands are
    // single-word work. `<>` allocates a binary proportional to its operands
    // and `|>` is a call, so neither is cheap.
    glance.BinaryOperator(name:, left:, right:, ..) ->
      cheap_operator(name) && cheap(left) && cheap(right)
    glance.Block(..)
    | glance.Case(..)
    | glance.Panic(..)
    | glance.Todo(..)
    | glance.Echo(..)
    | glance.BitString(..) -> False
  }
}

fn cheap_field(field: glance.Field(glance.Expression)) -> Bool {
  case field {
    glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
      cheap(item)
    glance.ShorthandField(..) -> True
  }
}

fn cheap_optional(value: Option(glance.Expression)) -> Bool {
  case value {
    Some(inner) -> cheap(inner)
    None -> True
  }
}

fn cheap_operator(operator: glance.BinaryOperator) -> Bool {
  case operator {
    glance.Concatenate | glance.Pipe -> False
    glance.And
    | glance.Or
    | glance.Eq
    | glance.NotEq
    | glance.LtInt
    | glance.LtEqInt
    | glance.LtFloat
    | glance.LtEqFloat
    | glance.GtEqInt
    | glance.GtInt
    | glance.GtEqFloat
    | glance.GtFloat
    | glance.AddInt
    | glance.AddFloat
    | glance.SubInt
    | glance.SubFloat
    | glance.MultInt
    | glance.MultFloat
    | glance.DivInt
    | glance.DivFloat
    | glance.RemainderInt -> True
  }
}

fn constructor_reference(function: glance.Expression) -> Bool {
  case function {
    glance.Variable(name:, ..) -> starts_upper(name)
    glance.FieldAccess(label:, ..) -> starts_upper(label)
    _ -> False
  }
}

fn starts_upper(name: String) -> Bool {
  case string.first(name) {
    Ok(first) -> string.lowercase(first) != first
    Error(Nil) -> False
  }
}

/// A short phrase naming what the eager argument actually is, so the report
/// says why it is not cheap rather than only that it is not.
fn describe(value: glance.Expression) -> String {
  case value {
    glance.Call(function:, arguments:, ..) ->
      case constructor_reference(function) {
        True -> "a constructor over " <> describe_costly(arguments)
        False -> "a call to `" <> callee_text(function) <> "`"
      }
    glance.BinaryOperator(name: glance.Concatenate, ..) ->
      "a `<>` concatenation"
    glance.BinaryOperator(name: glance.Pipe, ..) -> "a pipeline"
    glance.BinaryOperator(..) -> "an operator expression"
    glance.Block(..) -> "a block"
    glance.Case(..) -> "a `case` expression"
    glance.Panic(..) -> "`panic`"
    glance.Todo(..) -> "`todo`"
    glance.Echo(..) -> "an `echo`"
    glance.BitString(..) -> "a bit-string literal"
    glance.Tuple(..) | glance.List(..) | glance.RecordUpdate(..) ->
      "a constructed value"
    _ -> "a computed value"
  }
}

fn describe_costly(arguments: List(glance.Field(glance.Expression))) -> String {
  case list.filter(arguments, fn(field) { !cheap_field(field) }) {
    [glance.LabelledField(item:, ..), ..]
    | [glance.UnlabelledField(item:), ..] -> describe(item)
    _ -> "a computed value"
  }
}

fn callee_text(function: glance.Expression) -> String {
  case function {
    glance.Variable(name:, ..) -> name
    glance.FieldAccess(
      container: glance.Variable(name: qualifier, ..),
      label:,
      ..,
    ) -> qualifier <> "." <> label
    glance.FieldAccess(label:, ..) -> label
    _ -> "a function"
  }
}

fn span_of(value: glance.Expression) -> glance.Span {
  case value {
    glance.Int(location:, ..)
    | glance.Float(location:, ..)
    | glance.String(location:, ..)
    | glance.Variable(location:, ..)
    | glance.NegateInt(location:, ..)
    | glance.NegateBool(location:, ..)
    | glance.Block(location:, ..)
    | glance.Panic(location:, ..)
    | glance.Todo(location:, ..)
    | glance.Tuple(location:, ..)
    | glance.List(location:, ..)
    | glance.Fn(location:, ..)
    | glance.RecordUpdate(location:, ..)
    | glance.FieldAccess(location:, ..)
    | glance.Call(location:, ..)
    | glance.TupleIndex(location:, ..)
    | glance.FnCapture(location:, ..)
    | glance.BitString(location:, ..)
    | glance.Case(location:, ..)
    | glance.BinaryOperator(location:, ..)
    | glance.Echo(location:, ..) -> location
  }
}

// --- R5: an O(n) answer to a bounded question -------------------------------

fn binary(
  operator: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  let acc = case operator {
    glance.Eq
    | glance.NotEq
    | glance.LtInt
    | glance.LtEqInt
    | glance.GtInt
    | glance.GtEqInt -> bounded(left, right, ctx, acc)
    _ -> acc
  }
  case operator {
    glance.Pipe -> piped(right, ctx, expression(left, ctx, acc))
    _ -> expression(right, ctx, expression(left, ctx, acc))
  }
}

fn piped(right: glance.Expression, ctx: Ctx, acc: List(Raw)) -> List(Raw) {
  case right {
    glance.Call(function:, arguments:, ..) ->
      call(function, arguments, True, ctx, acc)
    _ -> expression(right, ctx, acc)
  }
}

/// A comparison is R5's business when one side counts a list and the other
/// is anything but another count: that is the shape where the answer is
/// settled by the first `k + 1` elements while the count walks all of them.
///
/// The bound need not be a literal. `list.length(xs) > max_results` is the
/// same hazard as `list.length(xs) > 24`, and in this tree it is the commoner
/// spelling. Two counts compared with each other are left alone: neither side
/// is a bound the other can stop at.
fn bounded(
  left: glance.Expression,
  right: glance.Expression,
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  case length_call(left, ctx), length_call(right, ctx) {
    Some(_), Some(_) -> acc
    Some(span), None -> [bounded_finding(span, int_literal(right), ctx), ..acc]
    None, Some(span) -> [bounded_finding(span, int_literal(left), ctx), ..acc]
    None, None -> acc
  }
}

fn bounded_finding(span: glance.Span, bound: Option(String), ctx: Ctx) -> Raw {
  let #(question, drop) = case bound {
    Some(literal) -> #(
      "a comparison against " <> literal,
      "list.drop(xs, " <> literal <> ")",
    )
    None -> #("a comparison against a bound", "list.drop(xs, bound)")
  }
  Raw(
    rule: finding.BoundedLength,
    offset: span.start,
    function: ctx.function,
    detail: "`list.length` walks the whole list to answer "
      <> question
      <> ", which only needs the elements up to it; test `"
      <> drop
      <> "` against `[]`, or match the list, and stop at the bound",
  )
}

/// The span of a `list.length` measurement, applied (`list.length(xs)`) or
/// piped (`xs |> list.length`).
fn length_call(value: glance.Expression, ctx: Ctx) -> Option(glance.Span) {
  case value {
    glance.Call(function:, location:, ..) ->
      case is_length(resolve(ctx.names, function)) {
        True -> Some(location)
        False -> None
      }
    glance.BinaryOperator(name: glance.Pipe, right:, location:, ..) ->
      case is_length(resolve(ctx.names, right)) {
        True -> Some(location)
        False -> None
      }
    // `{ xs |> list.length } > cap` — a block around one expression is
    // punctuation, not work.
    glance.Block(statements: [glance.Expression(inner)], ..) ->
      length_call(inner, ctx)
    _ -> None
  }
}

fn int_literal(value: glance.Expression) -> Option(String) {
  case value {
    glance.Int(value: text, ..) -> Some(text)
    glance.NegateInt(value: glance.Int(value: text, ..), ..) ->
      Some("-" <> text)
    _ -> None
  }
}

// --- R3: catch-all patterns -------------------------------------------------

fn case_(
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  let acc = expressions(subjects, ctx, acc)
  let single = case subjects {
    [_] -> True
    _ -> False
  }
  let reportable =
    { single || ctx.policy.catch_all_multi_subject }
    && !list.any(clauses, matches_a_primitive)
    && flat_variant_dispatch(clauses)
  let predicate = two_arm_predicate(clauses)
  list.fold(clauses, acc, fn(acc, clause) {
    clause_(clause, reportable, predicate, ctx, acc)
  })
}

fn clause_(
  clause: glance.Clause,
  reportable: Bool,
  predicate: Bool,
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  let acc = case
    reportable && clause.guard == None,
    catch_all_span(clause.patterns)
  {
    True, Some(span) -> [
      Raw(
        rule: finding.CatchAll,
        offset: span.start,
        function: ctx.function,
        detail: "`_ ->` swallows every remaining shape, so the compiler "
          <> "cannot tell you when a new variant needs handling here; "
          <> "enumerate the variants if the subject is a type you own"
          <> predicate_note(predicate),
      ),
      ..acc
    ]
    _, _ -> acc
  }
  optional(clause.guard, ctx, expression(clause.body, ctx, acc))
}

/// The span of the arm's final alternative when every pattern in it is a
/// discard — that is, when the arm matches regardless of the subject.
fn catch_all_span(patterns: List(List(glance.Pattern))) -> Option(glance.Span) {
  case list.reverse(patterns) {
    [alternative, ..] ->
      case list.all(alternative, is_discard), alternative {
        True, [first, ..] -> Some(pattern_span(first))
        _, _ -> None
      }
    [] -> None
  }
}

fn is_discard(pattern: glance.Pattern) -> Bool {
  case pattern {
    glance.PatternDiscard(..) -> True
    _ -> False
  }
}

/// The commonest benign catch-all: a two-arm predicate whose arms are both
/// constants, `case pattern { PatternDiscard(..) -> True  _ -> False }`.
/// Enumerating ten variants to return `False` is worse code, so the census
/// says which findings are this shape rather than quietly dropping them —
/// the reviewer, not the linter, decides whether a new variant belongs on
/// the `True` side.
fn two_arm_predicate(clauses: List(glance.Clause)) -> Bool {
  case clauses {
    [first, second] -> constant_body(first.body) && constant_body(second.body)
    _ -> False
  }
}

fn constant_body(body: glance.Expression) -> Bool {
  case body {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> True
    _ -> False
  }
}

fn predicate_note(predicate: Bool) -> String {
  case predicate {
    False -> ""
    True ->
      " — two-arm predicate over constants, the shape where `_ ->` is often"
      <> " the honest spelling"
  }
}

/// Is this `case` a flat dispatch over the variants of one type?
///
/// R3's target is the arm that hides a sibling variant, so that adding a
/// variant compiles instead of failing. That shape is a `case` whose other
/// arms are plain constructors — `Pending ->`, `Ok(rows) ->` — with nothing
/// but binders inside them.
///
/// A `case` whose arms match a *combination* — `Ok(Some(Cell(..))) ->` — or
/// a list or tuple shape is a different thing: `_ ->` there stands for the
/// remaining combinations, and enumerating them is usually neither possible
/// nor an improvement. Those are not flagged. This is the second decidable
/// narrowing R3 makes without types, and it is also where the rule
/// under-reports: a nested match over two small types would be enumerable,
/// and R3 will not say so.
fn flat_variant_dispatch(clauses: List(glance.Clause)) -> Bool {
  let dispatching =
    list.filter(clauses, fn(clause) { catch_all_span(clause.patterns) == None })
  case dispatching {
    [] -> False
    _ ->
      list.all(dispatching, fn(clause) {
        list.all(clause.patterns, fn(alternative) {
          list.all(alternative, is_flat_variant)
        })
      })
  }
}

fn is_flat_variant(pattern: glance.Pattern) -> Bool {
  case pattern {
    glance.PatternVariant(arguments:, ..) ->
      list.all(arguments, fn(field) {
        case field {
          glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
            is_binder(item)
          glance.ShorthandField(..) -> True
        }
      })
    glance.PatternDiscard(..) | glance.PatternVariable(..) -> True
    _ -> False
  }
}

fn is_binder(pattern: glance.Pattern) -> Bool {
  case pattern {
    glance.PatternDiscard(..) | glance.PatternVariable(..) -> True
    _ -> False
  }
}

/// Does any arm of this `case` match a literal, anywhere in a pattern?
///
/// If so the `case` discriminates on a primitive — an `Int`, a `Float`, a
/// `String`, a bit string — for which no exhaustive enumeration exists, so
/// `_ ->` is mandatory rather than a smell. The search goes into tuples,
/// lists and variant arguments, because `[0x22, ..rest] ->` discriminates on
/// an `Int` just as surely as `0x22 ->` does. Decidable from the AST alone,
/// and it removes the largest class of false positives R3 would otherwise
/// produce.
fn matches_a_primitive(clause: glance.Clause) -> Bool {
  list.any(clause.patterns, fn(alternative) {
    list.any(alternative, is_primitive_pattern)
  })
}

fn is_primitive_pattern(pattern: glance.Pattern) -> Bool {
  case pattern {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternConcatenate(..)
    | glance.PatternBitString(..) -> True
    glance.PatternAssignment(pattern:, ..) -> is_primitive_pattern(pattern)
    glance.PatternTuple(elements:, ..) ->
      list.any(elements, is_primitive_pattern)
    glance.PatternList(elements:, tail:, ..) ->
      list.any(elements, is_primitive_pattern)
      || case tail {
        Some(inner) -> is_primitive_pattern(inner)
        None -> False
      }
    glance.PatternVariant(arguments:, ..) ->
      list.any(arguments, fn(field) {
        case field {
          glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
            is_primitive_pattern(item)
          glance.ShorthandField(..) -> False
        }
      })
    glance.PatternDiscard(..) | glance.PatternVariable(..) -> False
  }
}

fn pattern_span(pattern: glance.Pattern) -> glance.Span {
  case pattern {
    glance.PatternInt(location:, ..)
    | glance.PatternFloat(location:, ..)
    | glance.PatternString(location:, ..)
    | glance.PatternDiscard(location:, ..)
    | glance.PatternVariable(location:, ..)
    | glance.PatternTuple(location:, ..)
    | glance.PatternList(location:, ..)
    | glance.PatternAssignment(location:, ..)
    | glance.PatternConcatenate(location:, ..)
    | glance.PatternBitString(location:, ..)
    | glance.PatternVariant(location:, ..) -> location
  }
}

// --- R2: nesting depth ------------------------------------------------------
//
// Depth is the longest chain of `case` expressions enclosing one another,
// counted on the AST. A seven-field constructor the formatter broke over
// seven lines contributes nothing, which is the entire reason this rule
// parses rather than measuring columns.

fn statements_depth(body: List(glance.Statement)) -> Int {
  list.fold(body, 0, fn(deepest, statement) {
    max(deepest, statement_depth(statement))
  })
}

fn statement_depth(statement: glance.Statement) -> Int {
  case statement {
    glance.Use(function:, ..) -> depth(function)
    glance.Expression(value) -> depth(value)
    glance.Assignment(value:, ..) -> depth(value)
    glance.Assert(expression: value, message:, ..) ->
      max(depth(value), optional_depth(message))
  }
}

fn depth(value: glance.Expression) -> Int {
  case value {
    glance.Case(subjects:, clauses:, ..) ->
      1
      + list.fold(clauses, deepest(subjects), fn(deepest, clause) {
        max(deepest, max(depth(clause.body), optional_depth(clause.guard)))
      })
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> 0
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      depth(inner)
    glance.Block(statements: body, ..) | glance.Fn(body:, ..) ->
      statements_depth(body)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      optional_depth(message)
    glance.Echo(expression: inner, message:, ..) ->
      max(optional_depth(inner), optional_depth(message))
    glance.Tuple(elements:, ..) -> deepest(elements)
    glance.List(elements:, rest:, ..) ->
      max(deepest(elements), optional_depth(rest))
    glance.RecordUpdate(record:, fields:, ..) ->
      list.fold(fields, depth(record), fn(deepest, field) {
        max(deepest, optional_depth(field.item))
      })
    glance.FieldAccess(container:, ..) -> depth(container)
    glance.TupleIndex(tuple:, ..) -> depth(tuple)
    glance.Call(function:, arguments:, ..) ->
      max(depth(function), field_depth(arguments))
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      max(
        depth(function),
        max(field_depth(arguments_before), field_depth(arguments_after)),
      )
    glance.BitString(segments:, ..) ->
      deepest(list.map(segments, fn(segment) { segment.0 }))
    glance.BinaryOperator(left:, right:, ..) -> max(depth(left), depth(right))
  }
}

fn field_depth(arguments: List(glance.Field(glance.Expression))) -> Int {
  list.fold(arguments, 0, fn(deepest, field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        max(deepest, depth(item))
      glance.ShorthandField(..) -> deepest
    }
  })
}

fn optional_depth(value: Option(glance.Expression)) -> Int {
  case value {
    Some(inner) -> depth(inner)
    None -> 0
  }
}

fn deepest(values: List(glance.Expression)) -> Int {
  list.fold(values, 0, fn(deepest, value) { max(deepest, depth(value)) })
}

fn max(left: Int, right: Int) -> Int {
  case left > right {
    True -> left
    False -> right
  }
}
