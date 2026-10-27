//// A `code_mode` program in the lane, drawn as one card.
////
//// The terminal draws a program as a block of text, and the lane used to draw
//// the same text. A page can show more: what the program did in one sentence,
//// the calls it made against its own clock, the program with its syntax
//// coloured, and a compiler's complaint with its line marked. The facts are
//// `session_view/program_card`'s (a pure projection of the call and its result,
//// shared with any other host); this module decides how they are laid out and
//// nothing about what they say.
////
//// ## The card
////
//// A card is a native `<details>`. Closed, it is one line: a glyph, the
//// outcome sentence (`Read 2 files, ran 4 git commands`), chips for the side
//// effects and the failures, the call count and the time. A settled program
//// with nothing wrong draws closed, so a long transcript reads one line per
//// program. A program that failed, or whose calls did, draws open on what went
//// wrong (`program_card.opening`). Under the line are three sections, each its
//// own `<details>`:
////
//// - Program shows its first lines and, when the host kept the whole text, a
////   control that shows all of it.
//// - Calls is a timeline, a row per run of consecutive calls to one
////   capability, each with a bar on the program's own time axis. A row opens
////   to every call of its run: the host's redacted argument summary, the error
////   code and the timing, and nothing else, because nothing else is recorded
////   about a call.
//// - Result shows the value's kind and keys and, when the host kept it, the
////   whole value. A failed program shows its error here instead, and a
////   compiler's diagnostic is laid out with its source and the line marked.
////
//// A program still running has no call record yet, so its card shows its
//// opening and the budget, and the time it has run is the browser's
//// (`<loom-elapsed>`), counted from when the call was recorded.
////
//// ## Safety
////
//// Every string a card holds is session text: a path in an argument summary, a
//// line of the program, the compiler's words. Each is a text node and nothing
//// else. A class comes from a `case` over a closed type (`State`, `ChipKind`,
//// `call_tree.Status`), never from the text. The only attributes built from
//// numbers are the two a bar's fill carries, whole percentages the projection
//// bounds. The card carries no handler, so an observer's page draws it as an
//// operator's does, and the browser owns what is open
//// (`docs/lustre.md`, protocol-change/051).
////
//// ## Flow
////
//// `view` → `head`, `program_section`, `calls_section`, `outcome_section`, `foot`
////
//// 1. `view` draws the card's line (`head`) and its body, memoized on the
////    card and the time the call was recorded.
//// 2. `program_section` draws the numbered opening and the whole program
////    (`source_lines`).
//// 3. `calls_section` draws a row per run of calls (`call_row`) with its bar
////    (`bar`).
//// 4. `outcome_section` draws the value, the error, or the diagnostic
////    (`diagnostic`), and `foot` closes the card.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import session_view/call_tree
import session_view/program_card.{
  type CallRow, type CallTable, type Chip, type Diagnostic, type Disclosure,
  type Failure, type Program, type ProgramCard, type SourceLine, type State,
  type Value, Collapsed, CompileFailed, Completed, Expanded, FailedCalls,
  Network, ProgramFailed, Ran, Rejected, RunFailed, Running, SourceLine, Wrote,
}
import session_view/transcript_lines
import web_view/code_view

/// A program as a card.
///
/// `since` is when the call was recorded, in Unix milliseconds, for a program
/// that has no result yet; the browser counts the time it has run from it.
/// The card is memoized on the card and `since`, so a capture that leaves a
/// program as it was draws nothing again.
///
/// ## Examples
///
/// ```gleam
/// // program_card.view(card, None)
/// ```
pub fn view(card: ProgramCard, since: Option(Int)) -> Element(message) {
  use <- element.memo([element.ref(card), element.ref(since)])
  let opening = program_card.opening(card)

  html.details(
    [attribute.class("pc"), state_class(card.state), ..disclosed(opening.card)],
    [
      html.summary([attribute.class("pc-head")], head(card, since)),
      html.div(
        [attribute.class("pc-body")],
        list.flatten([
          [program_section(card.program, opening.program)],
          calls_section(card, opening.calls),
          outcome_section(card, opening.result),
          foot(card),
        ]),
      ),
    ],
  )
}

/// The class that tints the card by how the program stands, a literal chosen
/// from the closed state.
fn state_class(state: State) -> Attribute(message) {
  case state {
    Running -> attribute.class("pc-run")
    Completed -> attribute.class("pc-ok")
    CompileFailed | Rejected | RunFailed | ProgramFailed ->
      attribute.class("pc-bad")
  }
}

// The `open` attribute of a section the card draws open, and none for one it
// draws shut. The browser keeps what the reader opens or closes afterwards.
fn disclosed(disclosure: Disclosure) -> List(Attribute(message)) {
  case disclosure {
    Expanded -> [attribute.open(True)]
    Collapsed -> []
  }
}

// --- the card's line ------------------------------------------------------

/// The line a closed card is: the glyph, the name, the sentence, the chips,
/// then the count and the time on the right. The status word is for a reader
/// that cannot see the glyph.
fn head(card: ProgramCard, since: Option(Int)) -> List(Element(message)) {
  list.flatten([
    [
      html.span([attribute.class("pc-glyph"), attribute.aria_hidden(True)], [
        html.text(glyph(card.state)),
      ]),
      html.span([attribute.class("pc-name")], [html.text("code_mode")]),
      html.span([attribute.class("pc-outcome")], [html.text(card.outcome)]),
    ],
    list.map(card.chips, chip),
    [html.span([attribute.class("pc-spacer")], [])],
    case card.count_words {
      Some(words) -> [
        html.span([attribute.class("pc-meta")], [html.text(words)]),
      ]
      None -> []
    },
    time(card, since),
    [html.span([attribute.class("sr-only")], [html.text(card.status_word)])],
  ])
}

/// Glyph helper.
fn glyph(state: State) -> String {
  case state {
    Running -> "◐"
    Completed -> "✓"
    CompileFailed | Rejected | RunFailed | ProgramFailed -> "×"
  }
}

/// A chip, its colour from the closed kind: signal for a side effect, danger
/// for a failure.
fn chip(chip: Chip) -> Element(message) {
  html.span(
    [
      attribute.class("pc-chip"),
      case chip.kind {
        Wrote -> attribute.class("pc-chip-wrote")
        Ran -> attribute.class("pc-chip-ran")
        Network -> attribute.class("pc-chip-network")
        FailedCalls -> attribute.class("pc-chip-failed")
      },
    ],
    [html.text(program_card.chip_words(chip))],
  )
}

/// How long the program ran: the record's time once it settled, and for one
/// still running the time the browser counts from when the call was recorded.
/// The element holds one number and no session text.
fn time(card: ProgramCard, since: Option(Int)) -> List(Element(message)) {
  case card.state, since, card.elapsed_ms {
    Running, Some(start), _ -> [
      html.span([attribute.class("pc-time")], [
        html.text("Running · "),
        element.element(
          "loom-elapsed",
          [attribute.attribute("since", int.to_string(start))],
          [],
        ),
      ]),
    ]
    Running, None, _ -> []
    Completed, _, Some(ms)
    | CompileFailed, _, Some(ms)
    | Rejected, _, Some(ms)
    | RunFailed, _, Some(ms)
    | ProgramFailed, _, Some(ms)
    -> [
      html.span([attribute.class("pc-time")], [
        html.text(transcript_lines.seconds_text(ms)),
      ]),
    ]
    Completed, _, None
    | CompileFailed, _, None
    | Rejected, _, None
    | RunFailed, _, None
    | ProgramFailed, _, None
    -> []
  }
}

// --- the program --------------------------------------------------------

/// The program's section: how many lines it has and how many show, its opening
/// lines numbered as the program numbers them, and, when the host kept the
/// whole text, a control that shows every line.
fn program_section(
  program: Program,
  disclosure: Disclosure,
) -> Element(message) {
  let shown = list.length(program.opening)

  // Dispatch on program_section state.
  let note = case program.lines > shown {
    True ->
      lines_words(program.lines) <> ", " <> int.to_string(shown) <> " shown"
    False -> lines_words(program.lines)
  }

  section(
    attribute.class("pc-program"),
    "Program",
    note,
    disclosure,
    list.flatten([
      [
        html.div([attribute.class("pc-preview")], [
          source_lines(program.opening, program.failing_line),
        ]),
      ],
      case program.whole {
        Some(whole) if program.lines > shown -> [
          // The stylesheet hides the preview while this is open, since the
          // whole listing starts with the same lines, and swaps the label
          // between its two spans by the element's own open state.
          html.details([attribute.class("pc-all")], [
            html.summary([attribute.class("pc-button")], [
              html.span([attribute.class("pc-when-closed")], [
                html.text(
                  "Show all " <> int.to_string(program.lines) <> " lines",
                ),
              ]),
              html.span([attribute.class("pc-when-open")], [
                html.text("Show fewer lines"),
              ]),
            ]),
            source_lines(numbered(whole), program.failing_line),
          ]),
        ]
        Some(_) | None -> []
      },
    ]),
  )
}

fn lines_words(lines: Int) -> String {
  case lines {
    1 -> "1 line"
    n -> int.to_string(n) <> " lines"
  }
}

// The text of a program as numbered lines, from 1.
fn numbered(text: String) -> List(SourceLine) {
  text
  |> string.split("\n")
  |> list.index_map(fn(line, index) { SourceLine(index + 1, line) })
}

/// Source lines under their numbers, each scanned for its syntax by the shared
/// highlighter. A line a compiler named is marked, so the eye finds it.
fn source_lines(
  lines: List(SourceLine),
  failing: Option(Int),
) -> Element(message) {
  html.div(
    [attribute.class("pc-src")],
    list.map(lines, fn(line) {
      html.div([attribute.class("pc-ln"), ..marked(line.number, failing)], [
        html.span([attribute.class("pc-n")], [
          html.text(int.to_string(line.number)),
        ]),
        html.span([attribute.class("pc-t")], [
          code_view.block(Some("gleam"), line.text),
        ]),
      ])
    }),
  )
}

// The mark on the line a compiler named, and none on any other.
fn marked(number: Int, failing: Option(Int)) -> List(Attribute(message)) {
  case failing {
    Some(named) if named == number -> [attribute.class("pc-hit")]
    Some(_) | None -> []
  }
}

// --- the calls ----------------------------------------------------------

/// The calls section, when the result carried a record: a timeline with a row
/// per run of consecutive calls, and a line for the calls the host counted and
/// did not list. A program with no record has no section.
fn calls_section(
  card: ProgramCard,
  disclosure: Disclosure,
) -> List(Element(message)) {
  case card.calls {
    None -> []
    Some(table) -> [
      section(
        attribute.class("pc-calls"),
        "Calls",
        table.summary,
        disclosure,
        list.flatten([
          [axis(table)],
          list.map(table.rows, call_row),
          unlisted(table),
        ]),
      ),
    ]
  }
}

// The axis the bars are drawn against: where the program began and where it
// ended.
fn axis(table: CallTable) -> Element(message) {
  html.div([attribute.class("pc-axis"), attribute.aria_hidden(True)], [
    html.span([], [html.text("0")]),
    html.span([], [html.text(transcript_lines.seconds_text(table.axis_ms))]),
  ])
}

/// Unlisted helper.
fn unlisted(table: CallTable) -> List(Element(message)) {
  case table.unlisted {
    0 -> []
    n -> [
      html.p([attribute.class("pc-more")], [
        html.text("… " <> int.to_string(n) <> " more calls not listed"),
      ]),
    ]
  }
}

/// One run of calls: its glyph, capability, count, key argument, bar and
/// ending on a line, and every call of the run behind it. The row's class says
/// how the run ended, and a failed run is tinted.
fn call_row(row: CallRow) -> Element(message) {
  html.details([attribute.class("pc-call"), ..row_class(row.status)], [
    html.summary([attribute.class("pc-call-line")], [
      html.span(
        [attribute.class("pc-call-glyph"), attribute.aria_hidden(True)],
        [
          html.text(call_glyph(row.status)),
        ],
      ),
      html.span([attribute.class("pc-call-cap")], [
        html.text(case row.count {
          1 -> row.cap
          n -> row.cap <> " ×" <> int.to_string(n)
        }),
      ]),
      html.span([attribute.class("pc-call-args")], [html.text(row.args)]),
      bar(row),
      html.span([attribute.class("pc-call-end")], [html.text(ending(row))]),
    ]),
    html.div([attribute.class("pc-call-detail")], call_detail(row)),
  ])
}

/// Row class helper.
fn row_class(status: call_tree.Status) -> List(Attribute(message)) {
  case status {
    call_tree.Settled -> [attribute.class("pc-call-ok")]
    call_tree.Failed -> [attribute.class("pc-call-failed")]
    call_tree.Cancelled -> [attribute.class("pc-call-cancelled")]
    call_tree.Unsettled -> [attribute.class("pc-call-open")]
  }
}

/// Call glyph helper.
fn call_glyph(status: call_tree.Status) -> String {
  case status {
    call_tree.Settled -> "✓"
    call_tree.Failed -> "×"
    call_tree.Cancelled -> "○"
    call_tree.Unsettled -> "◐"
  }
}

/// How a run ended, in words: its time, or `failed` with the error code, or
/// that it never settled.
fn ending(row: CallRow) -> String {
  let took = transcript_lines.seconds_text(row.duration_ms)

  // Dispatch on ending state.
  case row.status {
    call_tree.Settled -> took
    call_tree.Failed ->
      "failed"
      <> case row.error {
        Some(error) -> " · " <> error
        None -> ""
      }
      <> " · "
      <> took
    call_tree.Cancelled -> "cancelled"
    call_tree.Unsettled -> "not settled"
  }
}

/// The run's bar on the track. Its position and width are whole percentages the
/// projection bounds, the only numbers the card writes into an attribute; a
/// call still in flight when the program ended is hatched.
fn bar(row: CallRow) -> Element(message) {
  html.span([attribute.class("pc-bar"), attribute.aria_hidden(True)], [
    html.i(
      [
        attribute.class("pc-fill"),
        case row.status {
          call_tree.Settled -> attribute.class("pc-fill-ok")
          call_tree.Failed -> attribute.class("pc-fill-failed")
          call_tree.Cancelled -> attribute.class("pc-fill-cancelled")
          call_tree.Unsettled -> attribute.class("pc-fill-open")
        },
        attribute.styles([
          #("left", int.to_string(row.bar.offset) <> "%"),
          #("width", int.to_string(row.bar.width) <> "%"),
        ]),
      ],
      [],
    ),
  ])
}

/// What a run opens to: each of its calls with the summary, the start and the
/// time the record holds, the error code of a failed run, and a line saying
/// what the record does not hold.
fn call_detail(row: CallRow) -> List(Element(message)) {
  list.flatten([
    list.index_map(row.members, fn(member, index) {
      html.p([attribute.class("pc-member")], [
        html.text(int.to_string(index + 1) <> ". "),
        html.span([attribute.class("pc-member-args")], [
          html.text(option.unwrap(member.args, "no argument summary")),
        ]),
        html.span([attribute.class("pc-member-time")], [
          html.text(
            " · start +"
            <> transcript_lines.seconds_text(member.start_ms)
            <> " · "
            <> transcript_lines.seconds_text(member.duration_ms),
          ),
        ]),
      ])
    }),
    case row.error {
      Some(error) -> [
        html.p([attribute.class("pc-member-error")], [
          html.text("error code: " <> error),
        ]),
      ]
      None -> []
    },
    [
      html.p([attribute.class("pc-member-note")], [
        html.text(
          "The record holds the host's redacted summary, the error code and the timing of a call, not its arguments or its result.",
        ),
      ]),
    ],
  ])
}

// --- the result and the error -------------------------------------------

/// What the program came to: its value, its error, or, for a program still
/// running, a line saying the result is not there yet.
fn outcome_section(
  card: ProgramCard,
  disclosure: Disclosure,
) -> List(Element(message)) {
  case card.failure, card.value {
    Some(failure), _ -> [error_section(card, failure)]
    None, Some(value) -> [result_section(value, disclosure)]
    None, None -> [
      html.p([attribute.class("pc-pending")], [
        html.text(
          "The result, and the calls the program made, arrive when it ends.",
        ),
      ]),
    ]
  }
}

/// The value's kind and a hint per key, with the whole value behind a control
/// when the host kept it.
fn result_section(value: Value, disclosure: Disclosure) -> Element(message) {
  section(
    attribute.class("pc-result"),
    "Result",
    value.kind,
    disclosure,
    list.flatten([
      list.map(value.hints, fn(hint) {
        html.p([attribute.class("pc-hint")], [html.text(hint)])
      }),
      case value.whole {
        Some(whole) -> [
          html.details([attribute.class("pc-all")], [
            html.summary([attribute.class("pc-button")], [
              html.text("Show full value"),
            ]),
            html.pre([attribute.class("pc-raw")], [html.text(whole)]),
          ]),
        ]
        None -> []
      },
    ]),
  )
}

/// The error, always open: a compiler's diagnostic laid out by its parts, or
/// the text as it came, its first lines shown and the rest behind a control.
fn error_section(card: ProgramCard, failure: Failure) -> Element(message) {
  // Dispatch on error_section state.
  let note = case card.program.failing_line {
    Some(line) -> "line " <> int.to_string(line)
    None -> ""
  }

  section(
    attribute.class("pc-error"),
    "Error",
    note,
    Expanded,
    case failure.diagnostic {
      Some(found) -> diagnostic(found, failure)
      None -> [raw_text(failure)]
    },
  )
}

/// A compiler's report: its heading, where it points, the quoted source with
/// the failing line marked and the carets under it, and any note.
fn diagnostic(found: Diagnostic, failure: Failure) -> List(Element(message)) {
  [
    html.p([attribute.class("pc-errh")], [html.text(found.heading)]),
    html.p([attribute.class("pc-loc")], [
      html.text(
        found.path
        <> ":"
        <> int.to_string(found.line)
        <> ":"
        <> int.to_string(found.column),
      ),
    ]),
    html.div(
      [attribute.class("pc-src")],
      list.map(found.rows, fn(row) { report_row(row, Some(found.line)) }),
    ),
    html.details([attribute.class("pc-all")], [
      html.summary([attribute.class("pc-button")], [
        html.text(
          "Show all " <> int.to_string(failure.lines) <> " diagnostic lines",
        ),
      ]),
      html.pre([attribute.class("pc-raw")], [html.text(failure.text)]),
    ]),
  ]
}

/// Report row helper.
fn report_row(
  row: program_card.DiagRow,
  failing: Option(Int),
) -> Element(message) {
  case row {
    program_card.Quoted(number:, text:) ->
      html.div([attribute.class("pc-ln"), ..marked(number, failing)], [
        html.span([attribute.class("pc-n")], [html.text(int.to_string(number))]),
        html.span([attribute.class("pc-t")], [
          code_view.block(Some("gleam"), text),
        ]),
      ])
    program_card.Pointer(text:) ->
      html.div([attribute.class("pc-ln"), attribute.class("pc-caret")], [
        html.span([attribute.class("pc-n")], []),
        html.span([attribute.class("pc-t")], [html.text(text)]),
      ])
    program_card.Note(text:) ->
      html.div([attribute.class("pc-ln"), attribute.class("pc-note")], [
        html.span([attribute.class("pc-n")], []),
        html.span([attribute.class("pc-t")], [html.text(text)]),
      ])
  }
}

/// An error with no layout to give it: its first lines, and the rest behind a
/// control when there are more.
fn raw_text(failure: Failure) -> Element(message) {
  case string.split(failure.text, "\n") {
    [a, b, c, d, ..more] ->
      html.div([attribute.class("pc-rawwrap")], [
        html.pre([attribute.class("pc-raw")], [
          html.text(string.join([a, b, c, d], "\n")),
        ]),
        case more {
          [] -> element.none()
          [_, ..] ->
            html.details([attribute.class("pc-all")], [
              html.summary([attribute.class("pc-button")], [
                html.text(
                  "Show all " <> int.to_string(failure.lines) <> " lines",
                ),
              ]),
              html.pre([attribute.class("pc-raw")], [html.text(failure.text)]),
            ])
        },
      ])
    [_, ..] | [] ->
      html.pre([attribute.class("pc-raw")], [html.text(failure.text)])
  }
}

// --- the foot ------------------------------------------------------------

/// The card's last line: how long the program ran, why a failed one stopped,
/// and the budget the call asked for.
fn foot(card: ProgramCard) -> List(Element(message)) {
  let facts =
    list.flatten([
      case card.elapsed_ms {
        Some(ms) -> ["ran for " <> transcript_lines.seconds_text(ms)]
        None -> []
      },
      case card.failure {
        Some(failure) -> [failure.foot]
        None -> []
      },
      case card.budget_ms, card.failure {
        Some(ms), None -> ["budget " <> program_card.budget_words(ms)]
        Some(_), Some(_) | None, _ -> []
      },
    ])

  // Dispatch on foot state.
  case facts {
    [] -> []
    [_, ..] -> [
      html.p(
        [attribute.class("pc-foot")],
        list.map(facts, fn(fact) { html.span([], [html.text(fact)]) }),
      ),
    ]
  }
}

// --- sections --------------------------------------------------------------

/// One of the card's sections: a `<details>` whose line is the title and a
/// quiet note, open or shut as the projection says.
fn section(
  kind: Attribute(message),
  title: String,
  note: String,
  disclosure: Disclosure,
  body: List(Element(message)),
) -> Element(message) {
  html.details([attribute.class("pc-sec"), kind, ..disclosed(disclosure)], [
    html.summary([attribute.class("pc-sec-head")], [
      html.span([attribute.class("pc-sec-title")], [html.text(title)]),
      html.span([attribute.class("pc-sec-note")], [html.text(note)]),
    ]),
    html.div([attribute.class("pc-sec-body")], body),
  ])
}
