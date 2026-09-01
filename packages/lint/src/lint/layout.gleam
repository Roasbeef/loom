//// R10 and R11: whether the code was written in stanzas.
////
//// # Why a rule about blank lines
////
//// Loom's comment register is not decoration (`CLAUDE.md`, "Literate
//// code"): a reader should be able to follow a module's ownership model and
//// its failure behaviour by reading its prose in order. That only works if
//// the prose is *findable*, and what makes a comment findable is the blank
//// line above it. A comment welded to the statement above reads as that
//// statement's footnote; the same comment with a blank line above it is the
//// heading of the paragraph below, and the eye can skip between headings.
//// Every editor's fold, every diff hunk header, and every reader scanning a
//// four-hundred-line module for the part they need depends on that one
//// blank line.
////
//// The second half is the same argument without the comment. A function
//// written as one unbroken block of twenty statements has no paragraphs, so
//// there is nowhere for the prose to go and nothing for a reader to hold
//// onto between the top and the bottom. R11 measures that directly: the
//// longest run of statements with nothing between any two of them.
////
//// # Why this is a separate module
////
//// `glance` throws layout away. Comments are not in the AST at all and
//// blank lines leave no trace, so `lint/scan` — which is the AST walk and
//// nothing else — is structurally unable to answer either question. What
//// this module does instead is collect, from the tree, *where each sibling
//// begins*, and hand those offsets back to be resolved against the file's
//// own line table (`lint/source.classify`). The judgement is then made in
//// line numbers, over a classification made once per file.
////
//// # Why offsets and not lines
////
//// The walk emits byte offsets and asks about lines afterwards, which is
//// the same discipline `lint/scan` keeps and for the same reason: resolving
//// an offset to a line means walking the file's line index, so a conversion
//// per statement would be a walk of the file per statement. `blocks` runs
//// once, `source.line_map` resolves every offset it produced in one merged
//// pass, and `findings` reads the answers out of a table.
////
//// # What the rules do not look at
////
//// Neither rule counts lines of code. A `json.Object([#("k", …)])` literal
//// the formatter broke over thirty lines is one statement here, exactly as
//// it is depth zero to R2 — that distinction is the whole reason this tool
//// parses rather than measuring columns, and it applies to density just as
//// it applies to nesting. It follows that a comment *inside* such a literal
//// is invisible to R10: it annotates an element of a data structure rather
//// than opening a stanza, no blank line is owed above it, and the rule sees
//// only the gaps between siblings.

import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lint/finding
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines, Blank, Code, CommentLine}

/// A run of siblings that were written one after another, in byte offsets:
/// where each one begins, in source order.
///
/// Two kinds, because the two rules do not reach the same distance.
/// Statements are the paragraphs of a body, and both rules read them. Arms
/// of a `case` are a table rather than a paragraph — twelve one-line arms
/// dispatching a message type is exactly the right shape and no amount of
/// blank lines improves it — so R11 leaves them alone and only R10, which
/// asks about a comment somebody chose to write, applies.
pub type Block {
  /// The statements of one body: a function's, a block's, a closure's.
  /// `function` names the enclosing function and `at` is where its
  /// definition begins, which is where R11 reports — a density finding is
  /// about the function, the way R2's is.
  Statements(function: String, at: Int, steps: List(Step))
  /// The arms of one `case`.
  Branches(function: String, starts: List(Int))
}

/// One statement of a body: where it begins, and what it contributes to a
/// density run.
pub type Step {
  Step(at: Int, weight: Weight)
}

/// What a statement is worth to R11.
///
/// The distinction exists because the first census made the rule wrong
/// about the shape the style guide most recommends. `core/codec`'s
/// `decode_assistant_message` is nineteen statements with nothing between
/// them and it is not a dense block: it is nineteen `use field <-
/// result.try(…)` lines, a table of fields written down the page, and the
/// only way to satisfy a rule that counted them would be to break the table
/// at an arbitrary field. That is the same judgement R3 makes about a
/// `case` over combinations — the shape is not the shape the rule means —
/// and it is decidable the same way, from the syntax alone.
pub type Weight {
  /// A `let`, an expression, an `assert`: a step of the body's argument,
  /// and one unit of density.
  Ordinary
  /// A `use` binding. Worth nothing, and it does not break a run either:
  /// it carries the count across so that ten `let`s threaded through a
  /// decoder chain still read as ten.
  Binding
}

/// Every block in a parsed module, in no particular order.
pub fn blocks(module: glance.Module) -> List(Block) {
  list.flat_map(module.functions, fn(definition) {
    let function = definition.definition
    in_body(function.name, function.location.start, function.body)
  })
}

/// Every offset a block names, which is what `source.line_map` has to
/// resolve before `findings` can say anything.
pub fn offsets(blocks: List(Block)) -> List(Int) {
  list.flat_map(blocks, fn(block) {
    case block {
      Statements(at:, ..) -> [at, ..siblings(block)]
      Branches(..) -> siblings(block)
    }
  })
}

/// Where each sibling of a block begins, whichever kind of block it is.
/// R10 asks the same question of statements and of `case` arms, so it reads
/// them through this and never learns which it has.
fn siblings(block: Block) -> List(Int) {
  case block {
    Statements(steps:, ..) -> list.map(steps, fn(step) { step.at })
    Branches(starts:, ..) -> starts
  }
}

/// R10 and R11 over blocks whose offsets have been resolved to lines.
///
/// `at` is `source.line_map`'s table: every offset `offsets` produced,
/// mapped to the line it falls on.
pub fn findings(
  blocks: List(Block),
  lines: Lines,
  at: Dict(Int, Int),
  policy: Policy,
) -> List(Raw) {
  list.append(
    list.flat_map(blocks, fn(block) { orphan_comments(block, lines, at) }),
    dense_functions(blocks, lines, at, policy),
  )
}

// --- R10: a comment with no room above it -----------------------------------

/// Every comment between two siblings of this block that has code on the
/// line directly above it.
///
/// The gap between two siblings holds only three things: the continuation
/// lines of the earlier one, blank lines, and comments. So the question
/// "does a blank line separate this comment from the code above it" is
/// answered by walking up from the later sibling through the comment block
/// immediately above it and asking what sits above *that* — and the walk is
/// bounded at the earlier sibling's own first line, so it can never climb
/// out of the gap and blame a comment on a statement it does not belong to.
fn orphan_comments(
  block: Block,
  lines: Lines,
  at: Dict(Int, Int),
) -> List(Raw) {
  let function = case block {
    Statements(function:, ..) | Branches(function:, ..) -> function
  }

  // The first sibling of a block is exempt and has to be: `gleam format`
  // deletes a blank line at the top of a block, so a comment opening a body
  // *cannot* have one above it. Pairs, therefore, never the head.
  block
  |> siblings
  |> list.map(fn(start) { line_at(at, start) })
  |> pairs
  |> list.filter_map(fn(pair) { orphan(pair.0, pair.1, lines) })
  |> list.map(fn(line) { orphan_finding(line, function, lines) })
}

/// The topmost line of the comment block sitting directly above `current`,
/// when there is one and the line above it is code.
fn orphan(previous: Int, current: Int, lines: Lines) -> Result(Int, Nil) {
  case climb(current - 1, previous, lines) {
    // Nothing but code above the sibling: no comment, nothing to say.
    None -> Error(Nil)
    Some(top) ->
      case source.kind_of(lines, top - 1) {
        Code -> Ok(top)
        Blank | CommentLine -> Error(Nil)
      }
  }
}

/// Walk up from `line` while the lines are comments, stopping above
/// `floor` — the earlier sibling's first line, which is code by
/// construction and therefore ends the climb on its own.
fn climb(line: Int, floor: Int, lines: Lines) -> Option(Int) {
  case line > floor, source.kind_of(lines, line) {
    True, CommentLine ->
      case climb(line - 1, floor, lines) {
        Some(higher) -> Some(higher)
        None -> Some(line)
      }
    _, _ -> None
  }
}

fn orphan_finding(line: Int, function: String, lines: Lines) -> Raw {
  Raw(
    rule: finding.CommentStanza,
    offset: source.offset_of(lines, line),
    function:,
    detail: "this comment has code on the line directly above it, so it "
      <> "reads as a note on that line rather than as the heading of the "
      <> "stanza below; put a blank line above it (CLAUDE.md, \"Literate "
      <> "code\")",
  )
}

// --- R11: a body written as one block ---------------------------------------

/// One finding per function whose longest unbroken run of statements
/// exceeds the threshold.
///
/// Reported against the function rather than against the run, the way R2's
/// depth finding is: what a reader has to do about it is re-read the whole
/// body and decide where its paragraphs are, and a finding per gap would
/// say the same thing eight times. Runs from every statement list the
/// function contains — its own body, the blocks inside its `case` arms, the
/// bodies of its closures — count toward the same number, because a closure
/// written as one dense block is a dense block.
fn dense_functions(
  blocks: List(Block),
  lines: Lines,
  at: Dict(Int, Int),
  policy: Policy,
) -> List(Raw) {
  blocks
  |> list.fold(dict.new(), fn(longest, block) {
    case block {
      Branches(..) -> longest
      Statements(function:, at: start, steps:) -> {
        let run = longest_run(steps, lines, at)
        let seen = case dict.get(longest, start) {
          Ok(#(_, previous)) -> previous
          Error(Nil) -> 0
        }
        dict.insert(longest, start, #(function, int.max(run, seen)))
      }
    }
  })
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(start, #(function, run)) = entry
    case run > policy.dense_stanza_run {
      False -> Error(Nil)
      True -> Ok(dense_finding(start, function, run, policy))
    }
  })
}

/// The longest run of statements with nothing between any two of them.
///
/// A gap is *tight* when the line directly above a statement is code —
/// which, because the only things a gap can hold are the earlier
/// statement's own continuation lines, blanks and comments, is exactly the
/// condition "no blank line and no comment separates these two". Every
/// statement of a tight run adds its own weight, so a `use` chain carries
/// the count across without inflating it.
fn longest_run(steps: List(Step), lines: Lines, at: Dict(Int, Int)) -> Int {
  case steps {
    [] -> 0
    [first, ..] -> {
      let opening = weight(first)
      let #(longest, _) =
        list.fold(pairs(steps), #(opening, opening), fn(state, pair) {
          let #(longest, current) = state
          let #(_, next) = pair
          let run = case source.kind_of(lines, line_at(at, next.at) - 1) {
            Code -> current + weight(next)

            // A blank line or a comment ends the paragraph; the statement
            // below it opens the next one and counts as its first member.
            Blank | CommentLine -> weight(next)
          }
          #(int.max(longest, run), run)
        })
      longest
    }
  }
}

fn weight(step: Step) -> Int {
  case step.weight {
    Ordinary -> 1
    Binding -> 0
  }
}

fn dense_finding(at: Int, function: String, run: Int, policy: Policy) -> Raw {
  Raw(
    rule: finding.DenseStanza,
    offset: at,
    function:,
    detail: int.to_string(run)
      <> " statements run together with no blank line and no comment between "
      <> "any two of them (threshold "
      <> int.to_string(policy.dense_stanza_run)
      <> "); a body with no paragraphs has nowhere to put the prose that "
      <> "says what each step is for — break it into stanzas and name them. "
      <> "Counted in statements, so a wrapped literal is not density",
  )
}

// --- collecting the blocks --------------------------------------------------
//
// A second walk over `glance`'s expression tree, and deliberately a separate
// one from `lint/scan`'s: that walk carries name resolution, an eager
// combinator table and a finding accumulator, none of which mean anything
// here. What this one wants is narrow enough to say in a sentence — every
// list of siblings, and where each of them starts — so it is written as
// exactly that. Both walks are exhaustive over `glance.Expression` for the
// package's usual reason: a new syntax node must fail to compile here rather
// than quietly stop being looked at.

fn in_body(
  function: String,
  at: Int,
  body: List(glance.Statement),
) -> List(Block) {
  [
    Statements(function:, at:, steps: list.map(body, step_of)),
    ..list.flat_map(body, fn(statement) {
      in_statement(function, at, statement)
    })
  ]
}

fn in_statement(
  function: String,
  at: Int,
  statement: glance.Statement,
) -> List(Block) {
  case statement {
    glance.Use(function: value, ..) | glance.Expression(value) ->
      in_expression(function, at, value)
    glance.Assignment(value:, ..) -> in_expression(function, at, value)
    glance.Assert(expression: value, message:, ..) ->
      list.append(
        in_expression(function, at, value),
        in_optional(function, at, message),
      )
  }
}

fn in_expression(
  function: String,
  at: Int,
  value: glance.Expression,
) -> List(Block) {
  case value {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      in_expression(function, at, inner)

    // The two nested bodies: a `{ … }` block and a closure. Both are places
    // a dense run of statements can hide from a rule that only read the
    // function's own top level.
    glance.Block(statements: body, ..) | glance.Fn(body:, ..) ->
      in_body(function, at, body)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      in_optional(function, at, message)
    glance.Echo(expression: inner, message:, ..) ->
      list.append(
        in_optional(function, at, inner),
        in_optional(function, at, message),
      )
    glance.Tuple(elements:, ..) -> in_expressions(function, at, elements)
    glance.List(elements:, rest:, ..) ->
      list.append(
        in_expressions(function, at, elements),
        in_optional(function, at, rest),
      )
    glance.RecordUpdate(record:, fields:, ..) ->
      list.append(
        in_expression(function, at, record),
        list.flat_map(fields, fn(field) {
          in_optional(function, at, field.item)
        }),
      )
    glance.FieldAccess(container:, ..) -> in_expression(function, at, container)
    glance.Call(function: callee, arguments:, ..) ->
      list.append(
        in_expression(function, at, callee),
        in_fields(function, at, arguments),
      )
    glance.TupleIndex(tuple:, ..) -> in_expression(function, at, tuple)
    glance.FnCapture(function: callee, arguments_before:, arguments_after:, ..) ->
      list.append(
        in_expression(function, at, callee),
        list.append(
          in_fields(function, at, arguments_before),
          in_fields(function, at, arguments_after),
        ),
      )
    glance.BitString(segments:, ..) ->
      in_expressions(function, at, list.map(segments, fn(pair) { pair.0 }))
    glance.Case(subjects:, clauses:, ..) ->
      in_case(function, at, subjects, clauses)
    glance.BinaryOperator(left:, right:, ..) ->
      list.append(
        in_expression(function, at, left),
        in_expression(function, at, right),
      )
  }
}

fn in_case(
  function: String,
  at: Int,
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> List(Block) {
  let arms = Branches(function:, starts: list.filter_map(clauses, clause_start))
  [
    arms,
    ..list.append(
      in_expressions(function, at, subjects),
      list.flat_map(clauses, fn(clause) {
        list.append(
          in_expression(function, at, clause.body),
          in_optional(function, at, clause.guard),
        )
      }),
    )
  ]
}

fn in_expressions(
  function: String,
  at: Int,
  values: List(glance.Expression),
) -> List(Block) {
  list.flat_map(values, fn(value) { in_expression(function, at, value) })
}

fn in_optional(
  function: String,
  at: Int,
  value: Option(glance.Expression),
) -> List(Block) {
  case value {
    Some(inner) -> in_expression(function, at, inner)
    None -> []
  }
}

fn in_fields(
  function: String,
  at: Int,
  arguments: List(glance.Field(glance.Expression)),
) -> List(Block) {
  list.flat_map(arguments, fn(field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        in_expression(function, at, item)

      // `f(value:)` is a variable spelled short; nothing to descend into.
      glance.ShorthandField(..) -> []
    }
  })
}

/// Where a statement begins, and what it is worth to a density run.
///
/// Three of the four carry their own span; a bare expression statement is
/// the expression, so it borrows the walk's. Only `use` is weightless, for
/// the reason `Weight` gives.
fn step_of(statement: glance.Statement) -> Step {
  case statement {
    glance.Use(location:, ..) -> Step(at: location.start, weight: Binding)
    glance.Assignment(location:, ..) | glance.Assert(location:, ..) ->
      Step(at: location.start, weight: Ordinary)
    glance.Expression(value) ->
      Step(at: scan.span_of(value).start, weight: Ordinary)
  }
}

/// Where a `case` arm begins — its first pattern. A clause with no pattern
/// at all cannot be written, but the type admits it, so it contributes
/// nothing rather than a guessed offset.
fn clause_start(clause: glance.Clause) -> Result(Int, Nil) {
  case clause.patterns {
    [[first, ..], ..] -> Ok(first.location.start)
    _ -> Error(Nil)
  }
}

// --- small shared shapes ----------------------------------------------------

/// Each element paired with the one before it: `[a, b, c]` becomes
/// `[#(a, b), #(b, c)]`. Both rules are questions about what lies between
/// two adjacent siblings, and neither has anything to ask about the first.
fn pairs(values: List(a)) -> List(#(a, a)) {
  case values {
    [first, second, ..rest] -> [#(first, second), ..pairs([second, ..rest])]
    [] | [_] -> []
  }
}

/// The line an offset falls on. An offset the table does not hold cannot
/// arise — `offsets` produced exactly the keys `line_map` was given — and
/// answering 0 for one keeps every caller total without a `let assert`.
fn line_at(at: Dict(Int, Int), offset: Int) -> Int {
  case dict.get(at, offset) {
    Ok(line) -> line
    Error(Nil) -> 0
  }
}
