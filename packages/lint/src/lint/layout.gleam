//// R10, R11 and R21: whether the code was written in stanzas.
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
//// longest run of statements with nothing between any two of them, weighting
//// compound control-flow statements (`case` dispatches and multi-statement
//// closures or blocks) as two steps so branching walls cannot hide under a
//// flat statement count.
////
//// The third rule, R21 (`case-stanza`), applies both halves to `case`
//// statements specifically: a `case` statement in a multi-statement body
//// (or a sole-statement `case` with multi-statement block arms) is a control
//// point that owes an explanatory `//` comment above it and a blank line
//// separating it from any statement before or after it.
////
//// # Why this is a separate module
////
//// `glance` throws layout away. Comments are not in the AST at all and
//// blank lines leave no trace, so `lint/scan` — which is the AST walk and
//// nothing else — is structurally unable to answer these questions. What
//// this module does instead is collect, from the tree, *where each sibling
//// begins and ends*, and hand those offsets back to be resolved against the
//// file's own line table (`lint/source.classify`). The judgement is then made
//// in line numbers, over a classification made once per file.
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
//// None of the three rules counts lines of code. A `json.Object([#("k", …)])`
//// literal the formatter broke over thirty lines is one `Ordinary` statement
//// here, exactly as it is depth zero to R2 — that distinction is the whole
//// reason this tool parses rather than measuring columns, and it applies to
//// density just as it applies to nesting. It follows that a comment *inside*
//// such a literal is invisible to R10: it annotates an element of a data
//// structure rather than opening a stanza, no blank line is owed above it,
//// and the rule sees only the gaps between siblings.
////
//// ## Flow
////
//// `blocks` → `in_body` → `step_of` → `offsets` → `findings` →
//// `orphan_comments` / `dense_functions` / `case_stanzas`
////
//// 1. `blocks` walks the parsed module through `in_body` and `in_custom_types`
////    to collect every `Statements`, `Branches` and `Variants` sibling list,
////    using `step_of` to classify each statement's `Weight` and `StepShape`.
//// 2. `offsets` gathers every start, end and arm offset from those blocks so
////    `source.line_map` resolves them to line numbers in one merged pass.
//// 3. `findings` runs `orphan_comments` (R10), `dense_functions` (R11) and
////    `case_stanzas` (R21) over the resolved line table.

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
/// Statements are the paragraphs of a body, and R10, R11 and R21 all read
/// them. Arms of a `case` are a table rather than a paragraph — twelve
/// one-line arms dispatching a message type is the right shape and no amount
/// of blank lines improves it — so R11 leaves them alone and R10 asks only
/// about a comment somebody chose to write between arms.
pub type Block {
  /// The statements of one body: a function's, a block's, a closure's.
  /// `function` names the enclosing function and `at` is where its
  /// definition begins, which is where R11 reports — a density finding is
  /// about the function, the way R2's is.
  Statements(function: String, at: Int, steps: List(Step))

  /// The arms of one `case`.
  Branches(function: String, starts: List(Int))

  /// The variants of one custom type. `function` is the type's name, which
  /// is what `Raw.function` means at module level.
  ///
  /// The formatter's answer differs by position here and the rule follows
  /// it exactly: a blank line between two **variants** is preserved, and a
  /// blank line between two **fields of a constructor** is deleted. So
  /// variants are siblings R10 can ask about and fields are not, which is
  /// the same reasoning that exempts the first statement of a body — a rule
  /// must never ask for something `gleam format` takes away.
  Variants(function: String, starts: List(Int))
}

/// Whether any arm of a `case` expression has a multi-statement `{ … }` block
/// as its body.
pub type BlockArm {
  /// At least one arm body is a multi-statement `{ … }` block.
  HasBlockArm

  /// Every arm body is a single expression.
  FlatArms
}

/// Whether a statement is a `case` stanza that owes commentary and blank-line
/// separation from surrounding statements (R21).
pub type StepShape {
  /// A statement whose control flow is a `case` dispatch (`case …`,
  /// `let x = case …`, or `use x <- f(case …)`), carrying the byte offsets
  /// where each of its arms begins and whether any arm is a `{ … }` block.
  CaseStep(arm_starts: List(Int), has_block_arm: BlockArm)

  /// Any other statement.
  PlainStep
}

/// One statement of a body: where it begins and ends, what it contributes to
/// a density run, and whether it is a `case` stanza.
pub type Step {
  Step(
    /// The byte offset where the statement begins.
    at: Int,
    /// The byte offset of the last character of the statement.
    end: Int,
    /// What this statement contributes to an R11 density run.
    weight: Weight,
    /// Whether this statement is a `case` stanza for R21.
    shape: StepShape,
  )
}

/// What a statement is worth to R11.
///
/// The distinction exists because the first census made the rule wrong
/// about the shape the style guide most recommends. `core/codec`'s
/// `decode_assistant_message` is nineteen statements with nothing between
/// them and it is not a dense block: it is nineteen `use field <-
/// result.try(…)` lines, a table of fields written down the page, and the
/// only way to satisfy a rule that counted them would be to break the table
/// at an arbitrary field. Conversely, a statement that embeds a `case`
/// dispatch or a multi-statement closure (`process.spawn_unlinked(fn() { … })`,
/// `use x <- result.try(case …)`) packs a whole branch or inner body into one
/// step and counts as `Compound` so a wall of branching closures cannot pass
/// as a short paragraph.
pub type Weight {
  /// A plain `let`, expression, or `assert` with no embedded `case` or
  /// multi-statement body: one step of the body's argument, and one unit of
  /// density.
  Ordinary

  /// A statement (`let`, `use`, `assert`, or expression) that embeds control
  /// flow or a nested statement body — a `case` expression, a multi-statement
  /// closure or block, or a single-statement closure whose statement is
  /// itself compound. Worth two units of density.
  Compound

  /// A flat `use` binding with no embedded `case` or multi-statement body.
  /// Worth nothing, and it does not break a run either: it carries the count
  /// across so that ten `let`s threaded through a decoder chain still read
  /// as ten.
  Binding
}

/// Every block in a parsed module, in no particular order.
///
/// `code` is needed only for the custom types: `glance.Variant` carries no
/// `Span`, so where a variant begins has to be lexed rather than read off
/// the tree (`source.variant_offsets`).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(parsed) = glance.module("pub fn f(x) { x }\n")
/// assert layout.blocks(parsed, "pub fn f(x) { x }\n") != []
/// ```
///
pub fn blocks(module: glance.Module, code: String) -> List(Block) {
  let bodies =
    list.flat_map(module.functions, fn(definition) {
      let function = definition.definition
      in_body(function.name, function.location.start, function.body)
    })
  list.append(bodies, in_custom_types(module, code))
}

/// One `Variants` block per custom type, its variant heads in source order.
fn in_custom_types(module: glance.Module, code: String) -> List(Block) {
  let types = list.map(module.custom_types, fn(it) { it.definition })
  let spans =
    list.map(types, fn(custom) { #(custom.location.start, custom.location.end) })
  list.map2(types, source.variant_offsets(code, spans), fn(custom, starts) {
    Variants(function: custom.name, starts:)
  })
}

/// Every offset a block names, which is what `source.line_map` has to
/// resolve before `findings` can say anything.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(parsed) = glance.module("pub fn f(x) { x }\n")
/// let bs = layout.blocks(parsed, "pub fn f(x) { x }\n")
/// assert layout.offsets(bs) != []
/// ```
///
pub fn offsets(blocks: List(Block)) -> List(Int) {
  list.flat_map(blocks, fn(block) {
    case block {
      Statements(at:, steps:, ..) -> [at, ..step_offsets(steps)]
      Branches(..) | Variants(..) -> siblings(block)
    }
  })
}

/// Every start, end, and arm offset carried by `steps`.
fn step_offsets(steps: List(Step)) -> List(Int) {
  list.flat_map(steps, fn(step) {
    case step.shape {
      CaseStep(arm_starts:, ..) -> [step.at, step.end, ..arm_starts]
      PlainStep -> [step.at, step.end]
    }
  })
}

/// Where each sibling of a block begins, whichever kind of block it is.
/// R10 asks the same question of statements, of `case` arms and of type
/// variants, so it reads them through this and never learns which it has.
fn siblings(block: Block) -> List(Int) {
  case block {
    Statements(steps:, ..) -> list.map(steps, fn(step) { step.at })
    Branches(starts:, ..) | Variants(starts:, ..) -> starts
  }
}

/// R10, R11 and R21 over blocks whose offsets have been resolved to lines.
///
/// `at` is `source.line_map`'s table: every offset `offsets` produced,
/// mapped to the line it falls on.
///
/// ## Examples
///
/// ```gleam
/// let code = "pub fn f(x) {\n  x\n}\n"
/// let assert Ok(parsed) = glance.module(code)
/// let lines = source.classify(code)
/// let bs = layout.blocks(parsed, code)
/// let at = source.line_map(lines.starts, layout.offsets(bs))
/// assert layout.findings(bs, lines, at, policy.default()) == []
/// ```
///
pub fn findings(
  blocks: List(Block),
  lines: Lines,
  at: Dict(Int, Int),
  policy: Policy,
) -> List(Raw) {
  list.flatten([
    list.flat_map(blocks, fn(block) { orphan_comments(block, lines, at) }),
    dense_functions(blocks, lines, at, policy),
    list.flat_map(blocks, fn(block) { case_stanzas(block, lines, at) }),
  ])
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
  // Extract the owning function or type name before scanning sibling pairs.
  let function = case block {
    Statements(function:, ..)
    | Branches(function:, ..)
    | Variants(function:, ..) -> function
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

/// Constructs the R10 finding for a comment welded to the code line above it.
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
    // Only statement blocks contribute to a function's unbroken statement run.
    case block {
      Branches(..) | Variants(..) -> longest
      Statements(function:, at: start, steps:) -> {
        let run = longest_run(steps, lines, at)

        // Keep the maximum unbroken run across all statement lists in this
        // function.
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

    // Report only when the function's worst unbroken run strictly exceeds
    // the policy threshold.
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
/// statement of a tight run adds its own weight, so a flat `use` chain
/// carries the count across without inflating it while a compound statement
/// (`case` or multi-statement closure/block) adds two units.
fn longest_run(steps: List(Step), lines: Lines, at: Dict(Int, Int)) -> Int {
  // Seed the fold from the opening step and reset the counter on any blank or
  // comment line between adjacent steps.
  case steps {
    [] -> 0
    [first, ..] -> {
      let opening = weight(first)
      let #(longest, _) =
        list.fold(pairs(steps), #(opening, opening), fn(state, pair) {
          let #(longest, current) = state
          let #(_, next) = pair

          // A blank line or a comment ends the paragraph; the statement
          // below it opens the next one and counts as its first member.
          let run = case source.kind_of(lines, line_at(at, next.at) - 1) {
            Code -> current + weight(next)
            Blank | CommentLine -> weight(next)
          }

          #(int.max(longest, run), run)
        })
      longest
    }
  }
}

/// Returns the integer density weight contributed by `step`.
fn weight(step: Step) -> Int {
  case step.weight {
    Ordinary -> 1
    Compound -> 2
    Binding -> 0
  }
}

/// Constructs the R11 finding for a function whose unbroken statement run
/// exceeds `policy.dense_stanza_run`.
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

// --- R21: case stanza commentary and separation -----------------------------

/// Which `case` stanza requirement was missed, so `case_stanza_finding` takes
/// a domain type rather than naked booleans (R9).
type CaseStanzaGap {
  MissingCommentAndWelded
  MissingCommentOnly
  WeldedOnly
}

/// Checks `case` statements in `block` for explanatory commentary and
/// blank-line separation from adjacent statements.
fn case_stanzas(block: Block, lines: Lines, at: Dict(Int, Int)) -> List(Raw) {
  case block {
    Branches(..) | Variants(..) -> []
    Statements(function:, steps: [only], ..) ->
      sole_case_stanza(function, only, lines, at)
    Statements(function:, steps:, ..) ->
      multi_case_stanzas(function, steps, lines, at)
  }
}

/// Checks a single-statement body whose sole statement is a `case` with at
/// least one multi-statement `{ … }` block arm: it must carry a `//` comment
/// either above the `case` or above at least one of its arms.
fn sole_case_stanza(
  function: String,
  step: Step,
  lines: Lines,
  at: Dict(Int, Int),
) -> List(Raw) {
  // A single-statement `case` with flat arms is a dispatch table; one with a
  // multi-statement block arm owes commentary above the `case` or an arm.
  case step.shape {
    PlainStep | CaseStep(has_block_arm: FlatArms, ..) -> []
    CaseStep(arm_starts:, has_block_arm: HasBlockArm) -> {
      let start_line = line_at(at, step.at)
      let has_above = source.kind_of(lines, start_line - 1) == CommentLine
      let has_arm_comment =
        list.any(arm_starts, fn(arm) {
          source.kind_of(lines, line_at(at, arm) - 1) == CommentLine
        })

      // Report when neither the `case` nor any of its arms explains the
      // dispatch.
      case has_above || has_arm_comment {
        True -> []
        False -> [case_stanza_finding(step.at, function, MissingCommentOnly)]
      }
    }
  }
}

/// Checks every `case` statement in a multi-statement body (`steps` has two
/// or more statements) for a `//` comment above it and blank-line separation
/// from surrounding statements.
fn multi_case_stanzas(
  function: String,
  steps: List(Step),
  lines: Lines,
  at: Dict(Int, Int),
) -> List(Raw) {
  let total = list.length(steps)
  steps
  |> list.index_map(fn(step, index) { #(index, step) })
  |> list.filter_map(fn(entry) {
    let #(index, step) = entry
    check_multi_step(function, step, index, total, lines, at)
  })
}

/// Checks one `Step` at `index` inside a body of `total` statements (`total >= 2`).
fn check_multi_step(
  function: String,
  step: Step,
  index: Int,
  total: Int,
  lines: Lines,
  at: Dict(Int, Int),
) -> Result(Raw, Nil) {
  // Non-`case` steps are governed by R10 and R11; `case` steps must carry a `//`
  // heading and blank-line separation from surrounding statements.
  case step.shape {
    PlainStep -> Error(Nil)
    CaseStep(..) -> {
      let start_line = line_at(at, step.at)
      let end_line = line_at(at, step.end)
      let missing_comment = source.kind_of(lines, start_line - 1) != CommentLine
      let welded_before =
        index > 0 && source.kind_of(lines, start_line - 1) == Code
      let welded_after =
        index + 1 < total && source.kind_of(lines, end_line + 1) == Code
      let welded = welded_before || welded_after

      // Emit at most one R21 finding per `case` statement, naming whether
      // commentary, blank-line separation, or both are missing.
      case missing_comment, welded {
        False, False -> Error(Nil)
        True, True ->
          Ok(case_stanza_finding(step.at, function, MissingCommentAndWelded))
        True, False ->
          Ok(case_stanza_finding(step.at, function, MissingCommentOnly))
        False, True -> Ok(case_stanza_finding(step.at, function, WeldedOnly))
      }
    }
  }
}

/// Constructs the R21 finding for a `case` statement missing commentary or
/// blank-line separation.
fn case_stanza_finding(
  offset: Int,
  function: String,
  gap: CaseStanzaGap,
) -> Raw {
  // Describe the specific layout or commentary gap so the author knows
  // whether to add a `//` comment, a blank line, or both.
  let detail = case gap {
    MissingCommentAndWelded ->
      "this `case` statement has no `//` comment above it and is welded to "
      <> "an adjacent statement; open the `case` stanza with a blank line "
      <> "and a comment, and leave a blank line after it (CLAUDE.md, "
      <> "\"Literate code\")"
    MissingCommentOnly ->
      "this `case` statement has no `//` comment above it; state what the "
      <> "branch decides before dispatching (CLAUDE.md, \"Literate code\")"
    WeldedOnly ->
      "this `case` statement is welded to the statement after it; leave a "
      <> "blank line after a `case` stanza before the next statement "
      <> "(CLAUDE.md, \"Literate code\")"
  }

  Raw(rule: finding.CaseStanza, offset:, function:, detail:)
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

/// Collects the `Statements` block for `body` and recurses into every nested
/// statement.
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

/// Collects nested `Block`s inside one `glance.Statement`.
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

/// Collects nested `Block`s inside one `glance.Expression`.
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

/// Collects the `Branches` block for a `case` expression and recurses into
/// its subjects, guards, and arm bodies.
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

/// Collects nested `Block`s across a list of expressions.
fn in_expressions(
  function: String,
  at: Int,
  values: List(glance.Expression),
) -> List(Block) {
  list.flat_map(values, fn(value) { in_expression(function, at, value) })
}

/// Collects nested `Block`s inside an optional expression.
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

/// Collects nested `Block`s across call or capture argument fields.
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

/// Where a statement begins and ends, what it is worth to a density run, and
/// whether it is a `case` stanza.
///
/// Three of the four statement variants carry their own span; a bare
/// expression statement is the expression, so it borrows the walk's. A flat
/// `use` is `Binding` (weight 0), while any statement embedding a `case` or a
/// multi-statement closure/block is `Compound` (weight 2).
fn step_of(statement: glance.Statement) -> Step {
  let shape = step_shape(statement)

  // Extract the statement's span and compute its R11 density weight.
  case statement {
    glance.Use(location:, function: value, ..) -> {
      // A `use` whose call embeds a `case` or multi-statement closure is a
      // compound step rather than a weightless table row.
      let step_weight = case is_compound_expression(value) {
        True -> Compound
        False -> Binding
      }

      Step(
        at: location.start,
        end: span_end(location),
        weight: step_weight,
        shape:,
      )
    }

    glance.Assignment(location:, value:, ..) ->
      Step(
        at: location.start,
        end: span_end(location),
        weight: expression_weight(value),
        shape:,
      )

    glance.Assert(location:, expression: value, message:) -> {
      // Check both the asserted expression and its optional failure message
      // for embedded `case`s or multi-statement closures.
      let step_weight = case
        is_compound_expression(value) || is_compound_optional(message)
      {
        True -> Compound
        False -> Ordinary
      }

      Step(
        at: location.start,
        end: span_end(location),
        weight: step_weight,
        shape:,
      )
    }

    glance.Expression(value) -> {
      let location = scan.span_of(value)
      Step(
        at: location.start,
        end: span_end(location),
        weight: expression_weight(value),
        shape:,
      )
    }
  }
}

/// Classifies `value` as `Compound` when it embeds a `case` or multi-statement
/// body, or `Ordinary` otherwise.
fn expression_weight(value: glance.Expression) -> Weight {
  case is_compound_expression(value) {
    True -> Compound
    False -> Ordinary
  }
}

/// Returns the inclusive last byte offset of `span`.
fn span_end(span: glance.Span) -> Int {
  int.max(span.start, span.end - 1)
}

/// Determines whether `statement` is a `CaseStep` (`case …`, `let x = case …`,
/// or `use x <- f(case …)`) or a `PlainStep`.
fn step_shape(statement: glance.Statement) -> StepShape {
  case statement {
    glance.Expression(value) | glance.Assignment(value:, ..) ->
      case leading_case(value) {
        Some(clauses) ->
          CaseStep(
            arm_starts: list.filter_map(clauses, clause_start),
            has_block_arm: clauses_block_arm(clauses),
          )
        None -> PlainStep
      }

    glance.Use(function: callee, ..) ->
      case use_case(callee) {
        Some(clauses) ->
          CaseStep(
            arm_starts: list.filter_map(clauses, clause_start),
            has_block_arm: clauses_block_arm(clauses),
          )
        None -> PlainStep
      }

    glance.Assert(..) -> PlainStep
  }
}

/// Extracts the clauses of a leading `case` expression, including one piped
/// into a downstream transformation (`case x { … } |> f`).
fn leading_case(value: glance.Expression) -> Option(List(glance.Clause)) {
  case value {
    glance.Case(clauses:, ..) -> Some(clauses)
    glance.BinaryOperator(name: glance.Pipe, left:, ..) -> leading_case(left)
    glance.BinaryOperator(..)
    | glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
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
    | glance.BitString(..) -> None
  }
}

/// Extracts the clauses of a `case` expression passed directly as `callee` or
/// as an argument to `callee` in a `use` statement (`use x <- result.try(case …)`).
fn use_case(callee: glance.Expression) -> Option(List(glance.Clause)) {
  case callee {
    glance.Case(clauses:, ..) -> Some(clauses)
    glance.Call(arguments:, ..) -> find_case_argument(arguments)
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
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
    | glance.TupleIndex(..)
    | glance.FnCapture(..)
    | glance.BitString(..)
    | glance.BinaryOperator(..) -> None
  }
}

/// Returns the clauses of the first call argument that is a `case` expression.
fn find_case_argument(
  arguments: List(glance.Field(glance.Expression)),
) -> Option(List(glance.Clause)) {
  case arguments {
    [] -> None
    [field, ..rest] ->
      case field {
        glance.LabelledField(item: glance.Case(clauses:, ..), ..)
        | glance.UnlabelledField(item: glance.Case(clauses:, ..)) ->
          Some(clauses)
        glance.LabelledField(..)
        | glance.UnlabelledField(..)
        | glance.ShorthandField(..) -> find_case_argument(rest)
      }
  }
}

/// Checks whether any clause in `clauses` has a multi-statement `{ … }` block
/// as its body.
fn clauses_block_arm(clauses: List(glance.Clause)) -> BlockArm {
  let has_block =
    list.any(clauses, fn(clause) {
      case clause.body {
        glance.Block(statements: [_, _, ..], ..) -> True
        glance.Block(statements: [], ..)
        | glance.Block(statements: [_], ..)
        | glance.Int(..)
        | glance.Float(..)
        | glance.String(..)
        | glance.Variable(..)
        | glance.NegateInt(..)
        | glance.NegateBool(..)
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
    })

  // Convert the boolean check into the domain type `BlockArm`.
  case has_block {
    True -> HasBlockArm
    False -> FlatArms
  }
}

/// Whether `statement` embeds a `case` expression or a multi-statement body.
fn is_compound_statement(statement: glance.Statement) -> Bool {
  case statement {
    glance.Use(function: value, ..)
    | glance.Expression(value)
    | glance.Assignment(value:, ..) -> is_compound_expression(value)
    glance.Assert(expression: value, message:, ..) ->
      is_compound_expression(value) || is_compound_optional(message)
  }
}

/// Whether `value` embeds a `case` expression, a multi-statement closure or
/// block, or a single-statement closure/block whose statement is compound.
/// Exhaustive over `glance.Expression`.
fn is_compound_expression(value: glance.Expression) -> Bool {
  case value {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> False
    glance.NegateInt(value: inner, ..) | glance.NegateBool(value: inner, ..) ->
      is_compound_expression(inner)
    glance.Block(statements:, ..) | glance.Fn(body: statements, ..) ->
      is_compound_body(statements)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      is_compound_optional(message)
    glance.Echo(expression: inner, message:, ..) ->
      is_compound_optional(inner) || is_compound_optional(message)
    glance.Tuple(elements:, ..) -> list.any(elements, is_compound_expression)
    glance.List(elements:, rest:, ..) ->
      list.any(elements, is_compound_expression) || is_compound_optional(rest)
    glance.RecordUpdate(record:, fields:, ..) ->
      is_compound_expression(record)
      || list.any(fields, fn(field) { is_compound_optional(field.item) })
    glance.FieldAccess(container:, ..) -> is_compound_expression(container)
    glance.Call(function: callee, arguments:, ..) ->
      is_compound_expression(callee) || is_compound_fields(arguments)
    glance.TupleIndex(tuple:, ..) -> is_compound_expression(tuple)
    glance.FnCapture(function: callee, arguments_before:, arguments_after:, ..) ->
      is_compound_expression(callee)
      || is_compound_fields(arguments_before)
      || is_compound_fields(arguments_after)
    glance.BitString(segments:, ..) ->
      list.any(segments, fn(pair) { is_compound_expression(pair.0) })
    glance.Case(..) -> True
    glance.BinaryOperator(left:, right:, ..) ->
      is_compound_expression(left) || is_compound_expression(right)
  }
}

/// Whether a nested statement list (inside a closure or `{ … }` block) is
/// compound: two or more statements, or one statement that is itself compound.
fn is_compound_body(statements: List(glance.Statement)) -> Bool {
  case statements {
    [] -> False
    [only] -> is_compound_statement(only)
    [_, _, ..] -> True
  }
}

/// Whether an optional expression is compound.
fn is_compound_optional(value: Option(glance.Expression)) -> Bool {
  case value {
    Some(inner) -> is_compound_expression(inner)
    None -> False
  }
}

/// Whether any field in `arguments` contains a compound expression.
fn is_compound_fields(
  arguments: List(glance.Field(glance.Expression)),
) -> Bool {
  list.any(arguments, fn(field) {
    case field {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        is_compound_expression(item)
      glance.ShorthandField(..) -> False
    }
  })
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
