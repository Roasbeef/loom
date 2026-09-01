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
import lint/policy.{type Counted, type Eager, type Policy}

/// One violation, located by byte offset. `lint` turns the offset into a
/// line; the walk has no idea what a line is.
pub type Raw {
  Raw(rule: Rule, offset: Int, function: String, detail: String)
}

/// Local names in scope: what a qualifier resolves to, what an unqualified
/// value was imported from, and — for R1's structural half — every function
/// this module defines for itself, so a bare call to one of them resolves
/// to `#(own_path, name)` the same way an imported one resolves to
/// `#(module, name)`. Nothing else in the walk needs to know a call is
/// local; it is just another entry the eager-combinator lookup can match.
type Names {
  Names(
    qualifiers: Dict(String, String),
    values: Dict(String, #(String, String)),
    local_functions: Dict(String, Nil),
    own_path: String,
  )
}

type Ctx {
  Ctx(names: Names, policy: Policy, function: String, locals: List(Eager))
}

/// Every violation in a parsed module, in no particular order.
///
/// `own_path` is this file's own module path (`tools/fs`, not the
/// filesystem path) — the same shape `policy.eager_combinators`' `module`
/// field uses for an imported one. It is what lets a call to a
/// locally-defined combinator resolve at all (`resolve` has no import to
/// consult for a function the file defines for itself) and what a
/// structurally-detected local combinator's synthesized `Eager` rows are
/// keyed under, so they only ever match calls inside the file that defines
/// them.
pub fn module(
  module: glance.Module,
  policy: Policy,
  own_path: String,
  imported: List(Eager),
) -> List(Raw) {
  let names = names_of(module, own_path)

  // This file's own rows, plus the ones other files exported. A row keyed
  // under `own_path` can only have come from this file, so dropping those
  // from `imported` is what keeps a public combinator from being counted
  // twice at its own call sites.
  let locals =
    list.append(
      local_eager_rows(module, own_path),
      list.filter(imported, fn(row) { row.module != own_path }),
    )
  let found =
    list.flat_map(module.functions, fn(definition) {
      let function = definition.definition
      let ctx = Ctx(names:, policy:, function: function.name, locals:)
      list.reverse(statements(function.body, ctx, nesting(function, ctx)))
    })
  found
  |> list.append(lone_callers(module, policy))
  |> list.append(naked_bools(module))
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

// --- R8: a long signature with exactly one caller ---------------------------
//
// A private function with eleven parameters that one place calls is not a
// hazard the way an eager fallback is; it is a shape, and this rule is a
// census of that shape rather than a verdict about it. What it measures is
// the thing a nesting metric rewards and never charges for: a block lifted
// out of its caller with the caller's locals re-declared as a signature.
// The tree gets shallower, the same state is threaded by hand through a
// contract only one call site ever satisfies, and nothing but the argument
// order checks it.
//
// It over-reports by construction — some of these are perfectly good
// helpers that will grow a second caller next week — so it can never be
// promoted past warning, exactly like R3. The number is the point: it would
// have named `reconcile_orphaned_poll` (thirteen parameters, one caller) on
// the commit that introduced it, and nothing did.
//
// "Caller" here means another function in this module whose body mentions
// the name, which over-counts (a shadowed local of the same name reads as a
// call) and so under-reports, and does not see a reference from a constant.
// Recursion is not a caller: a function that calls itself and is called
// once is the same shape as one that does not.

fn lone_callers(module: glance.Module, policy: Policy) -> List(Raw) {
  list.flat_map(module.functions, fn(definition) {
    let function = definition.definition
    case function.publicity, over_arity(function, policy.lone_caller_arity) {
      glance.Private, True ->
        lone_caller_finding(function, callers(module, function.name))
      _, _ -> []
    }
  })
}

/// Strictly more parameters than the threshold — asked with `list.drop`
/// rather than `list.length`, for R5's own reason.
fn over_arity(function: glance.Function, threshold: Int) -> Bool {
  list.drop(function.parameters, threshold) != []
}

/// How many other functions in this module mention this name.
fn callers(module: glance.Module, name: String) -> Int {
  module.functions
  |> list.filter(fn(other) { other.definition.name != name })
  |> list.count(fn(other) { mentions_in(other.definition.body, name) })
}

fn lone_caller_finding(function: glance.Function, callers: Int) -> List(Raw) {
  case callers {
    1 -> [
      Raw(
        rule: finding.LoneCallerArity,
        offset: function.location.start,
        function: function.name,
        detail: "`"
          <> function.name
          <> "` takes "
          <> int.to_string(list.length(function.parameters))
          <> " parameters and one function calls it; a signature that long "
          <> "with one caller is usually a block lifted out of that caller "
          <> "with its locals re-declared as parameters, so nothing checks "
          <> "the argument order but the types — group them into a record "
          <> "the two share, or put the block back. A census, not a verdict",
      ),
    ]
    _ -> []
  }
}

// --- R9: a Bool with nothing on it ------------------------------------------
//
// `Bool` is the one type in the language that carries no domain meaning at
// all. `render(document, True)` tells a reader nothing, and finding out what
// the `True` was costs a jump to the signature; a field declared `retry:
// Bool` makes every reader carry the polarity of the name in their head, and
// makes `Retry | GiveUp` — which cannot be got backwards — impossible to
// write later without touching every construction site. The style guide has
// said "replace booleans with two-variant custom types" and "small private
// enums beat boolean parameters" since it was written (Part III, "Type
// design"); nothing enforced it, and the tree now holds two hundred of them.
//
// The rule looks at the two positions where a `Bool` is a *value someone
// hands over*: a function parameter and a record field. Both are read at a
// distance from their declaration, which is the whole hazard.
//
// **Return position is deliberately not this rule's business.** `is_empty(xs)
// -> Bool` is the predicate `case`, `&&` and `bool.guard` are built to
// consume, the stdlib's own `is_*` vocabulary is in the guide's naming table,
// and a rule that flagged those would flag the language. A function that
// answers a domain question with a domain type is better, but "better" is
// not what a linter can decide here, and 179 returns of undecidable
// disposition would bury the 200 parameters and fields that are decidable.
//
// The search descends through type parameters and tuples — `Option(Bool)` in
// a field is the same hazard with a third state bolted on, and `Dict(String,
// Bool)` is a set that forgot to say what membership means — but never into
// a `fn(…)`, because a predicate *passed* to a function is that same
// legitimate `is_*` arriving as an argument (`list.filter(xs, is_ready)`).
// That boundary is the one narrowing the rule makes, and it is decidable
// without types: the annotation says `fn` or it does not.
//
// Type aliases and constants are not searched. An alias is a name someone
// already gave the shape, and its expansion is checked wherever it is
// declared as a parameter or a field.

fn naked_bools(module: glance.Module) -> List(Raw) {
  list.append(parameter_bools(module), field_bools(module))
}

fn parameter_bools(module: glance.Module) -> List(Raw) {
  list.flat_map(module.functions, fn(definition) {
    let function = definition.definition
    list.flat_map(function.parameters, fn(parameter) {
      naked_bool_finding(
        parameter.type_,
        function.name,
        "parameter `" <> parameter_label(parameter) <> "`",
        "the call site reads `True`, which names nothing",
      )
    })
  })
}

fn field_bools(module: glance.Module) -> List(Raw) {
  list.flat_map(module.custom_types, fn(definition) {
    let custom_type = definition.definition
    list.flat_map(custom_type.variants, fn(variant) {
      list.flat_map(variant.fields, fn(field) {
        naked_bool_finding(
          Some(field_type(field)),
          custom_type.name,
          in_variant(custom_type.name, variant.name) <> field_name(field),
          "every reader has to carry the polarity of the name",
        )
      })
    })
  })
}

/// One finding per declaration, at the `Bool` itself rather than at the
/// declaration that contains it: `Dict(String, Bool)` should underline the
/// value type, which is the half that has to change.
fn naked_bool_finding(
  type_: Option(glance.Type),
  enclosing: String,
  subject: String,
  because: String,
) -> List(Raw) {
  case option.then(type_, bool_within) {
    None -> []
    Some(span) -> [
      Raw(
        rule: finding.NakedBool,
        offset: span.start,
        function: enclosing,
        detail: subject
          <> " is a `Bool`, so "
          <> because
          <> "; a two-variant type — `Retry | GiveUp`, `Leading | Trailing` "
          <> "— says which state it is at both ends and cannot be got "
          <> "backwards (gleam-style Part III, \"No naked `Bool`\", which "
          <> "has the three escapes)",
      ),
    ]
  }
}

/// Where a `Bool` appears inside this annotation, if one does.
///
/// Descends through the parameters of a named type and the elements of a
/// tuple, so `Option(Bool)` and `#(Bool, Seq)` are found. Stops at a
/// `fn(…)`: a predicate handed to a function is the `is_*` shape the rule
/// deliberately leaves alone, arriving as an argument rather than as a
/// return.
fn bool_within(type_: glance.Type) -> Option(glance.Span) {
  case type_ {
    glance.NamedType(name: "Bool", module: None, parameters: [], location:) ->
      Some(location)
    glance.NamedType(parameters:, ..) -> first_bool(parameters)
    glance.TupleType(elements:, ..) -> first_bool(elements)
    glance.FunctionType(..) -> None
    glance.VariableType(..) | glance.HoleType(..) -> None
  }
}

fn first_bool(types: List(glance.Type)) -> Option(glance.Span) {
  case types {
    [] -> None
    [first, ..rest] ->
      case bool_within(first) {
        Some(span) -> Some(span)
        None -> first_bool(rest)
      }
  }
}

fn field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item:, ..)
    | glance.UnlabelledVariantField(item:) -> item
  }
}

/// Which variant a field belongs to, said only when it adds something.
/// Gleam's struct is a single variant sharing the type's name, and
/// "`Entry`: Entry's `revoked` field" spends a clause saying `Entry` twice.
fn in_variant(type_name: String, variant: String) -> String {
  case type_name == variant {
    True -> "the "
    False -> variant <> "'s "
  }
}

/// How the finding names a field. An unlabelled one has only its position
/// to be known by, and saying so is more use than inventing an index the
/// reader would have to count out.
fn field_name(field: glance.VariantField) -> String {
  case field {
    glance.LabelledVariantField(label:, ..) -> "`" <> label <> "` field"
    glance.UnlabelledVariantField(..) -> "unlabelled field"
  }
}

// --- name resolution --------------------------------------------------------

fn names_of(module: glance.Module, own_path: String) -> Names {
  let local_functions =
    list.fold(module.functions, dict.new(), fn(locals, definition) {
      dict.insert(locals, definition.definition.name, Nil)
    })
  let base =
    Names(
      qualifiers: dict.new(),
      values: dict.new(),
      local_functions:,
      own_path:,
    )
  list.fold(module.imports, base, fn(names, imported) {
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
    Names(..names, qualifiers:, values:)
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
        Error(Nil) ->
          // Not imported — but a bare call to one of this file's own
          // functions is exactly as legal Gleam, and just as reachable a
          // combinator, as an imported one. Resolve it under this file's
          // own path so the eager-combinator lookup can match it.
          case dict.has_key(names.local_functions, name) {
            True -> Some(#(names.own_path, name))
            False -> None
          }
      }
    _ -> None
  }
}

/// Every eager-combinator row that matches a call to `path.name` — the
/// hand-curated table plus this file's own structurally-detected local
/// combinators. Usually zero or one; a local combinator with more than one
/// eager parameter contributes one row per parameter, so all of them fire
/// off a single call site.
fn eager_specs(ctx: Ctx, path: String, name: String) -> List(Eager) {
  let matches = fn(spec: Eager) { spec.module == path && spec.function == name }
  list.append(
    list.filter(policy.eager_combinators(), matches),
    list.filter(ctx.locals, matches),
  )
}

// --- R1's other half: use-compatible combinators this file defines ---------
//
// `bool.guard`, `result.unwrap` and the rest of `policy.eager_combinators`
// are known by *name*: someone hand-curated the table. The
// `or_fault → or_fail → or_outcome → or_reply → or_continue` lineage
// (gleam-style Part III, "Short-circuit combinators") is the same hazard on
// roughly seventy locally-defined functions the table has never heard of —
// and the style guide now actively recommends writing more of them. This
// finds them by *signature* instead: the house pattern is "the fallible
// subject first, the continuation last" (verbatim from the guide), so a
// function whose last parameter is `fn(…)` and whose other parameters are
// not is `use`-compatible the same way `bool.guard` is, whoever wrote it.
//
// The subject at position 0 is deliberately left alone — it is meant to be
// computed unconditionally (`or_fault(plan_batch(…), then)`'s subject is
// real work, not a discarded fallback) — so only the parameters *between*
// the subject and the continuation are eager in R1's sense. A two-parameter
// combinator (`or_fault`, `or_halt`, `or_key_halt`: just a subject and a
// continuation) contributes nothing to check, which is why this rule adds
// findings without flooding the report across the whole lineage.
//
// The signature alone is not enough, and the first census proved it: nine
// of R1's thirty-three findings were parameters that merely *sat* between
// the subject and the continuation and were used unconditionally by the
// callee — `session.read_cell`'s `key:` goes straight into the register
// read, `claimed_effect`'s `key:` drives the claim check itself. Nothing
// about those is a discarded fallback (issue #73, C).
//
// So the body is read as well as the signature, and the question asked of
// it is the one the rule actually means: **does this combinator branch on
// its subject, and is the parameter outside that branch?** The decision is
// the subject of a leading `case` or the first argument of a leading `use
// <- guard(…)`; a combinator that branches on nothing, or on something
// other than its own first parameter, is not the shape this rule knows and
// contributes nothing. A parameter named in the decision is not a fallback:
// the combinator has already used it by the time it chooses, so evaluating
// it eagerly costs nothing that was not going to be spent.
//
// Both halves of that are decidable without types — a name appears in an
// expression or it does not — and both are conservative in the same
// direction: an unrecognized body shape drops the rows rather than
// inventing them. What is left is still not a proof that the argument is
// wasted (a `case` arm that ignores the continuation may use the parameter
// anyway), so the rule keeps reporting rather than gating, and stays a
// warning.

/// The rows a module *exports*: the same synthesis, restricted to the
/// functions another file could call.
///
/// `tools/tool.or_outcome` has nineteen call sites and sixteen of them are
/// in other modules, so a table built one file at a time was blind to the
/// large majority of the lineage's uses — clean by luck rather than by
/// coverage (issue #73, D). A row is keyed under the defining module's own
/// path either way, which is exactly what a qualified call resolves to, so
/// nothing in the lookup had to change: only where the rows come from.
pub fn exported_eager_rows(
  module: glance.Module,
  own_path: String,
) -> List(Eager) {
  list.flat_map(module.functions, fn(definition) {
    case definition.definition.publicity {
      glance.Public -> combinator_rows(definition.definition, own_path)
      glance.Private -> []
    }
  })
}

/// One synthesized `Eager` row per checkable parameter of every
/// `use`-compatible function this module defines, private ones included.
/// Keyed under `own_path`, which is what a bare call inside this file and a
/// qualified call from another one both resolve to.
fn local_eager_rows(module: glance.Module, own_path: String) -> List(Eager) {
  list.flat_map(module.functions, fn(definition) {
    combinator_rows(definition.definition, own_path)
  })
}

fn combinator_rows(function: glance.Function, own_path: String) -> List(Eager) {
  case list.reverse(function.parameters) {
    [last, ..reversed_rest] ->
      case
        is_continuation(last, function.return),
        list.any(reversed_rest, fn(param) { is_function_type(param.type_) })
      {
        // Last parameter is `fn(…)`, and it is the only one — this is a
        // candidate. Anything else with a second function-typed parameter
        // (`or_fail`'s `to_error`, say) is a different shape and left alone.
        True, False -> {
          let leading = list.reverse(reversed_rest)
          case decision(function.body, leading) {
            None -> []
            Some(subject) ->
              leading
              |> list.index_map(fn(param, index) { #(param, index) })
              |> list.filter(fn(pair) { pair.1 > 0 })
              // A parameter the decision reads is not a fallback: the
              // combinator has already used it by the time it chooses.
              |> list.filter(fn(pair) { !mentions(subject, binding(pair.0)) })
              |> list.map(fn(pair) {
                eager_row(function.name, own_path, pair.0, pair.1)
              })
          }
        }
        _, _ -> []
      }
    [] -> []
  }
}

/// The expression this combinator branches on, when it branches on its own
/// subject — the parameter at position 0.
///
/// Two shapes, which are the two ways the house pattern writes a
/// short-circuit: the subject of a leading single-subject `case`
/// (`or_fault`, `or_fault_unless`), and the first argument of a leading
/// `use <- guard(…)` (`claimed_effect`, and every `use x <- result.try(…)`
/// that opens a function). Anything else — a `let` first, a body that
/// branches on something other than its subject — is `None`, and the rows
/// are dropped rather than guessed at.
fn decision(
  body: List(glance.Statement),
  parameters: List(glance.FunctionParameter),
) -> Option(glance.Expression) {
  use subject <- option.then(branch_of(body))
  use first <- option.then(option.from_result(list.first(parameters)))
  case mentions(subject, binding(first)) {
    True -> Some(subject)
    False -> None
  }
}

/// The leading `case`'s subject or the leading `use`'s first argument.
///
/// The catch-all is over *combinations* — a list, a statement, an
/// expression and another list at once — not over an AST node, so it does
/// not weaken the exhaustiveness this package keeps over `glance`'s types:
/// a new syntax node adds a shape this cannot recognize, and an
/// unrecognized shape is already `None`.
fn branch_of(body: List(glance.Statement)) -> Option(glance.Expression) {
  case body {
    [glance.Expression(glance.Case(subjects: [subject], ..)), ..] ->
      Some(subject)
    [glance.Use(function: glance.Call(arguments: [first, ..], ..), ..), ..] ->
      case first {
        glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
          Some(item)

        // `guard(when:)` given as shorthand names a variable this walk
        // would have to synthesize a node for; drop the rows instead.
        glance.ShorthandField(..) -> None
      }
    _ -> None
  }
}

/// The name a parameter is bound to inside the body, which is what a
/// mention would spell — never its label, which the caller spells.
/// A discarded parameter cannot be mentioned at all.
fn binding(parameter: glance.FunctionParameter) -> String {
  case parameter.name {
    glance.Named(name) -> name
    glance.Discarded(name) -> "_" <> name
  }
}

/// Does `name` appear as a variable anywhere in this expression?
///
/// Over-approximates in the safe direction: a shadowing binding inside a
/// closure counts as a mention, which drops a row rather than inventing
/// one. Exhaustive over `glance.Expression` for the reason everything in
/// this file is — a new syntax node must fail to compile here rather than
/// quietly stop being searched.
fn mentions(value: glance.Expression, name: String) -> Bool {
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

fn mentions_in(body: List(glance.Statement), name: String) -> Bool {
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

fn eager_row(
  function: String,
  own_path: String,
  parameter: glance.FunctionParameter,
  position: Int,
) -> Eager {
  policy.Eager(
    module: own_path,
    function:,
    label: parameter_label(parameter),
    position:,
    // The detail this lands in already says an eager argument is built on
    // every call; a whole sentence here rendered as backticks inside
    // backticks (issue #73, report quality).
    lazy: "a thunk in place of the value",
  )
}

fn parameter_label(parameter: glance.FunctionParameter) -> String {
  case parameter.label {
    Some(label) -> label
    None ->
      case parameter.name {
        glance.Named(name) -> name
        glance.Discarded(name) -> name
      }
  }
}

/// Is this last parameter a *continuation* rather than a callback?
///
/// A continuation produces the combinator's own result — `or_fault(result,
/// then: fn(a) -> Action) -> Action` — which is what makes the call
/// `use`-compatible and what makes the parameters between subject and
/// continuation look like fallbacks. A function that merely takes a closure
/// last is doing something else with it: `call.try_call(subject, waiting:,
/// sending: fn(reply) -> message) -> Result(reply, CallFault)` builds a
/// request with `sending:` and uses `waiting:` unconditionally on every
/// path that gets that far.
///
/// Left implicit while the table was built one file at a time, because a
/// callback-taking function had to be defined beside its own call sites to
/// be seen at all. Reading the whole tree's exports made it load-bearing:
/// the first row the cross-module pass added was `try_call`'s, and it was
/// wrong (issue #73, D).
///
/// Decided by the two types being *spelled* the same, which is syntactic
/// and conservative in the direction everything here is: an unannotated
/// return, or the same type written two ways, drops the rows instead of
/// inventing them.
fn is_continuation(
  parameter: glance.FunctionParameter,
  return: Option(glance.Type),
) -> Bool {
  case parameter.type_, return {
    Some(glance.FunctionType(return: produced, ..)), Some(declared) ->
      same_type(produced, declared)
    _, _ -> False
  }
}

/// Are these the same type, written twice?
///
/// `glance` puts a `Span` on every type node, so `==` also compares *where*
/// each was written and a type is never equal to itself in another
/// position. The catch-all is over combinations of two nodes rather than
/// over a node, so it does not weaken the exhaustiveness this file keeps
/// over `glance`'s types: a new type node is unrecognized on both sides and
/// unrecognized already means "not the same", which drops rows rather than
/// inventing them.
fn same_type(left: glance.Type, right: glance.Type) -> Bool {
  case left, right {
    glance.NamedType(name: name, module: module, parameters: parameters, ..),
      glance.NamedType(
        name: other_name,
        module: other_module,
        parameters: other_parameters,
        ..,
      )
    ->
      name == other_name
      && module == other_module
      && same_types(parameters, other_parameters)
    glance.TupleType(elements:, ..), glance.TupleType(elements: other, ..) ->
      same_types(elements, other)
    glance.FunctionType(parameters:, return:, ..),
      glance.FunctionType(parameters: other, return: other_return, ..)
    -> same_types(parameters, other) && same_type(return, other_return)
    glance.VariableType(name:, ..), glance.VariableType(name: other, ..) ->
      name == other
    glance.HoleType(name:, ..), glance.HoleType(name: other, ..) ->
      name == other
    _, _ -> False
  }
}

fn same_types(left: List(glance.Type), right: List(glance.Type)) -> Bool {
  case list.strict_zip(left, right) {
    Error(Nil) -> False
    Ok(pairs) -> list.all(pairs, fn(pair) { same_type(pair.0, pair.1) })
  }
}

fn is_function_type(type_: Option(glance.Type)) -> Bool {
  case type_ {
    Some(glance.FunctionType(..)) -> True
    _ -> False
  }
}

/// Which of R5's counting calls this target names, if any.
fn counted(target: Option(#(String, String))) -> Option(Counted) {
  case target {
    Some(#(path, name)) ->
      policy.counted_calls()
      |> list.find(fn(call) { call.module == path && call.function == name })
      |> option.from_result
    None -> None
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
      expression(value, ctx, unnamed_assert(kind, location, ctx, acc))
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

/// R7. A `let assert` that is admitted — by the harness exemption or by an
/// argument in review — still owes the reader the invariant it rests on.
///
/// This is R4's other half rather than a second opinion about R4's
/// question. R4 asks whether the construct belongs in this file at all and
/// `policy.harness_packages` answers "here, yes"; Part IV rule 3 then asks
/// what the crash report will say, and a bare `let assert Ok(x) = …` answers
/// with a pattern and a line number. When it fires in production the message
/// is the only thing an operator gets, so the rule fires wherever the
/// construct is allowed to live — the harness included, which is where all
/// ninety of them are.
fn unnamed_assert(
  kind: glance.AssignmentKind,
  location: glance.Span,
  ctx: Ctx,
  acc: List(Raw),
) -> List(Raw) {
  case kind, ctx.policy.assert_message {
    glance.LetAssert(message: None), True -> [
      Raw(
        rule: finding.AssertWithoutMessage,
        offset: location.start,
        function: ctx.function,
        detail: "`let assert` without `as \"…\"` crashes with a pattern and "
          <> "a line number, which is the whole of what the operator gets; "
          <> "name the invariant that was violated (gleam-style Part IV, "
          <> "rule 3)",
      ),
      ..acc
    ]
    _, _ -> acc
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
      list.fold(eager_specs(ctx, path, name), acc, fn(acc, spec) {
        eager(spec, function, arguments, piped, ctx, acc)
      })
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

/// Where an expression was written. `glance` puts a `Span` on every
/// expression node but gives no accessor for it, because the field is not
/// shared across the variants in a way field access can reach.
///
/// Public for `lint/layout`, which needs the start of a bare-expression
/// statement in order to know which line a sibling begins on.
pub fn span_of(value: glance.Expression) -> glance.Span {
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
  case counted_call(left, ctx), counted_call(right, ctx) {
    Some(_), Some(_) -> acc
    Some(found), None -> [
      bounded_finding(found, int_literal(right), ctx),
      ..acc
    ]
    None, Some(found) -> [bounded_finding(found, int_literal(left), ctx), ..acc]
    None, None -> acc
  }
}

fn bounded_finding(
  found: #(glance.Span, Counted),
  bound: Option(String),
  ctx: Ctx,
) -> Raw {
  let #(span, call) = found
  let #(question, stop) = case bound {
    Some(literal) -> #(
      "a comparison against " <> literal,
      call.stop <> literal <> ")",
    )
    None -> #("a comparison against a bound", call.stop <> "bound)")
  }
  Raw(
    rule: finding.BoundedLength,
    offset: span.start,
    function: ctx.function,
    detail: "`"
      <> last_segment(call.module)
      <> "."
      <> call.function
      <> "` walks the whole "
      <> call.noun
      <> " to answer "
      <> question
      <> ", which only needs the "
      <> call.unit
      <> " up to it; test `"
      <> stop
      <> "` against `"
      <> call.empty
      <> "` and stop at the bound",
  )
}

/// The span of a counting measurement and which count it is, applied
/// (`list.length(xs)`) or piped (`xs |> string.length`).
fn counted_call(
  value: glance.Expression,
  ctx: Ctx,
) -> Option(#(glance.Span, Counted)) {
  case value {
    glance.Call(function:, location:, ..) ->
      counted(resolve(ctx.names, function))
      |> option.map(fn(call) { #(location, call) })
    glance.BinaryOperator(name: glance.Pipe, right:, location:, ..) ->
      counted(resolve(ctx.names, right))
      |> option.map(fn(call) { #(location, call) })

    // `{ xs |> list.length } > cap` — a block around one expression is
    // punctuation, not work.
    glance.Block(statements: [glance.Expression(inner)], ..) ->
      counted_call(inner, ctx)
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
    && !list.any(clauses, is_guarded)
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
  // No guard test here: a `case` with a guarded arm anywhere is not
  // reportable at all, which `case_` has already decided.
  let acc = case reportable, catch_all_of(clause.patterns) {
    True, Some(spelling) -> [
      Raw(
        rule: finding.CatchAll,
        offset: offset_of(spelling),
        function: ctx.function,
        detail: swallows(spelling, clause.body) <> predicate_note(predicate),
      ),
      ..acc
    ]
    _, _ -> acc
  }
  optional(clause.guard, ctx, expression(clause.body, ctx, acc))
}

/// A guarded arm cannot be the whole of its pattern, so the compiler
/// demands a fallback arm however many variants are enumerated above it.
/// The `_ ->` under a guarded sibling is therefore mandatory, and a finding
/// about it is always wrong — twelve of them in the first census (issue
/// #73, B). This is the third narrowing R3 makes without types.
fn is_guarded(clause: glance.Clause) -> Bool {
  clause.guard != None
}

/// How a catch-all arm is spelled. Both shapes match regardless of the
/// subject and both disable the exhaustiveness check; they differ in what
/// the reader has to do about it, so the finding says which one it found.
type CatchAll {
  /// `_ ->`.
  Discarded(span: glance.Span)
  /// `other ->`. A bare variable is a catch-all whatever it is called
  /// (gleam-style Part III), and it is the spelling R3 could not see at
  /// all until issue #73 — seventy-three arms as measured, including
  /// every one of the serious ones the baseline review found, and all
  /// nine of `core`'s.
  Bound(span: glance.Span, name: String)
}

fn offset_of(spelling: CatchAll) -> Int {
  case spelling {
    Discarded(span:) | Bound(span:, ..) -> span.start
  }
}

/// What the finding says, which is not the same sentence for the two
/// spellings.
///
/// A `_ ->` can often be deleted and the variants enumerated in its place.
/// An `other ->` whose body *reads* `other` cannot: each enumerated arm has
/// to name the value it matched, so the reviewer is looking at a larger
/// edit and wants to sort those apart from the rest. One whose body never
/// reads it is a `_ ->` wearing a name, and says so.
fn swallows(spelling: CatchAll, body: glance.Expression) -> String {
  let swallowed =
    " swallows every remaining shape, so the compiler cannot tell you when "
    <> "a new variant needs handling here; "
  case spelling {
    Discarded(..) ->
      "`_ ->`"
      <> swallowed
      <> "enumerate the variants if the subject is a type you own"
    Bound(name:, ..) ->
      "`"
      <> name
      <> " ->` is a catch-all with a name on it: it"
      <> swallowed
      <> case mentions(body, name) {
        True ->
          "the arm reads `"
          <> name
          <> "`, so enumerating the variants means naming the value in each"
        False ->
          "the arm never reads `"
          <> name
          <> "`, so this is `_ ->` with a label on it"
      }
  }
}

/// The arm's final alternative when every pattern in it matches regardless
/// of the subject — a discard or a bare variable — and how it is spelled.
fn catch_all_of(patterns: List(List(glance.Pattern))) -> Option(CatchAll) {
  case list.reverse(patterns) {
    [alternative, ..] ->
      case list.all(alternative, is_catch_all), alternative {
        True, [first, ..] -> spelling(first)
        _, _ -> None
      }
    [] -> None
  }
}

/// A discard or a bare variable: the two patterns that match anything.
fn spelling(pattern: glance.Pattern) -> Option(CatchAll) {
  case pattern {
    glance.PatternDiscard(location:, ..) -> Some(Discarded(span: location))
    glance.PatternVariable(location:, name:) ->
      Some(Bound(span: location, name:))
    _ -> None
  }
}

fn is_catch_all(pattern: glance.Pattern) -> Bool {
  spelling(pattern) != None
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
    list.filter(clauses, fn(clause) { catch_all_of(clause.patterns) == None })
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
