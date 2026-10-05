//// The Trace tab of the strand panel: the `code_mode` programs the session
//// ran, the newest one first on screen with its state, its result excerpt
//// and a collapsed Budget line, and the earlier ones under it in order.
////
//// The trace is `session_view/trace_view`, folded from the records the page
//// already holds, so nothing here reads anything the page does not have and
//// nothing is sent. It lists programs and not the capability calls inside
//// them, because no capability call is recorded (`trace_view` says why, and
//// the pane says so in its last line, so an empty-looking program is not read
//// as one that did nothing). Timing bars wait on that record too.
////
//// The pane is the panel's fourth (`view/panel`), placed after Session and
//// before the advisor's nudges, so the paths the Strands and Session panes
//// hold (`component.strip_path`, `component.invite_path`) do not move. The
//// shell shows it while its tab is chosen; it is drawn whether or not it
//// shows, and the tab's button is the shell's. A session with no `code_mode`
//// call draws the heading and one line saying so, so the pane keeps its
//// place and the tab never opens on nothing.
////
//// Every string a program carries is session text: the label and the excerpt
//// are drawn as text nodes and nowhere else, never as an attribute, a class
//// or a key. A state's class is a complete literal chosen from the closed
//// `trace_view.State`, never derived from the result's `status` word or from
//// the state's name. The view carries no handler, so an observer's page
//// draws it as an operator's does. The fold bounds the list
//// (`trace_view.max_programs`) and a cut is drawn as a line saying how many
//// earlier programs are not shown.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/trace_view.{
  type Program, type State, type Trace, CompileFailed, Completed, Errored,
  Failed, Rejected, RunFailed, Running,
}

/// The Trace pane for `trace`.
///
/// It is memoized on the trace, so a page whose programs did not change
/// diffs nothing.
///
/// ## Examples
///
/// ```gleam
/// // trace.view(component.trace(model))
/// ```
pub fn view(trace: Trace) -> Element(message) {
  use <- element.memo([element.ref(trace)])
  html.section(
    [
      attribute.class("pane"),
      attribute.class("pane-trace"),
      attribute.aria_label("Trace"),
    ],
    case list.reverse(trace.programs) {
      [] -> [
        title(),
        html.p([attribute.class("pane-empty")], [
          html.text("No program yet."),
        ]),
      ]
      [latest, ..earlier] -> [
        title(),
        latest_program(latest),
        earlier_programs(earlier, trace.omitted),
        no_calls(latest),
      ]
    },
  )
}

fn title() -> Element(message) {
  html.h2([attribute.class("panel-title")], [html.text("Trace")])
}

// The newest program: its label and state on one line, its result under
// them, and the budget it named in a collapsed line.
fn latest_program(program: Program) -> Element(message) {
  html.div([attribute.class("trace-latest")], [
    html.p([attribute.class("trace-head")], [
      html.span([attribute.class("trace-label")], [html.text(program.label)]),
      state_chip(program.state),
    ]),
    result(program),
    calls(program.calls),
    html.p([attribute.class("trace-budget")], [
      html.text("Budget · " <> trace_view.budget_words(program)),
    ]),
  ])
}

// What the program came to. A program that did not compile or run shows its
// own diagnostics (`Program.detail`), never the result's text, which is
// written to tell the model what to fix; one with no diagnostics shows
// nothing rather than that text. Every other state shows its excerpt.
fn result(program: Program) -> Element(message) {
  case program.state, program.detail {
    CompileFailed, Some(detail)
    | RunFailed, Some(detail)
    | Rejected, Some(detail)
    -> diagnostic(detail)
    CompileFailed, None | RunFailed, None | Rejected, None -> element.none()
    Running, _ | Completed, _ | Errored, _ | Failed, _ ->
      case program.excerpt {
        Some(excerpt) ->
          html.p([attribute.class("trace-result")], [html.text(excerpt)])
        None -> element.none()
      }
  }
}

// A failure's diagnostics in the code face: their first two lines, and the
// rest behind a chevron when there is more. The text is the compiler's or the
// runtime's, drawn as text nodes.
fn diagnostic(detail: String) -> Element(message) {
  case string.split(detail, "\n") {
    [first, second, third, ..more] ->
      html.details([attribute.class("trace-diagnostic")], [
        html.summary([attribute.class("trace-result")], [
          html.text(first <> "\n" <> second),
        ]),
        html.pre([attribute.class("trace-result")], [
          html.text(string.join([third, ..more], "\n")),
        ]),
      ])
    [_] | [_, _] | [] ->
      html.pre(
        [attribute.class("trace-result"), attribute.class("trace-diagnostic")],
        [html.text(detail)],
      )
  }
}

// A line saying so when the newest program has no call record, so a program
// that shows no calls is not read as one that made none.
fn no_calls(program: Program) -> Element(message) {
  case program.calls {
    [] ->
      html.p([attribute.class("trace-note")], [
        html.text("No calls recorded."),
      ])
    [_, ..] -> element.none()
  }
}

// The rows of the call record the result carried: a heading and one row per
// call, as text nodes. A program with no record draws nothing here.
fn calls(rows: List(String)) -> Element(message) {
  case rows {
    [] -> element.none()
    [heading, ..rest] ->
      html.div([attribute.class("trace-calls")], [
        html.p([attribute.class("trace-calls-heading")], [html.text(heading)]),
        html.ul(
          [attribute.class("trace-call-list")],
          list.map(rest, fn(row) {
            html.li([attribute.class("trace-call")], [html.text(row)])
          }),
        ),
      ])
  }
}

// The earlier programs, newest first under the latest, and a line for any
// the bound left out.
fn earlier_programs(earlier: List(Program), omitted: Int) -> Element(message) {
  case earlier, omitted {
    [], 0 -> element.none()
    _, _ ->
      html.div([attribute.class("trace-earlier")], [
        html.h3([attribute.class("trace-subtitle")], [html.text("Earlier")]),
        html.ul([attribute.class("trace-list")], list.map(earlier, row)),
        case omitted {
          0 -> element.none()
          left ->
            html.p([attribute.class("trace-cut")], [
              html.text(int.to_string(left) <> " older programs not shown"),
            ])
        },
      ])
  }
}

fn row(program: Program) -> Element(message) {
  html.li([attribute.class("trace-row")], [
    html.span([attribute.class("trace-label")], [html.text(program.label)]),
    state_chip(program.state),
    why(program),
  ])
}

// The reason an earlier program did not run, in one line under its row: the
// first line of what `trace_view` kept as its detail, which for a refusal is
// the vetting rule that was broken. A state that is only a word (`rejected by
// vetting`) says what happened and not why, and the newest program alone
// showed the reason, so a refusal that was fixed and run again left no reason
// anywhere. A program that ran, or is running, has nothing to explain.
fn why(program: Program) -> Element(message) {
  case program.state, program.detail {
    Rejected, Some(detail)
    | CompileFailed, Some(detail)
    | RunFailed, Some(detail)
    ->
      case first_line(detail) {
        "" -> element.none()
        line -> html.p([attribute.class("trace-why")], [html.text(line)])
      }
    _, _ -> element.none()
  }
}

// The first line with words, cut to a row's worth with an ellipsis.
fn first_line(detail: String) -> String {
  let line =
    detail
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.find(fn(line) { line != "" })
    |> result.unwrap("")
  case string.length(line) > why_limit {
    True -> string.slice(line, 0, why_limit - 1) <> "…"
    False -> line
  }
}

// The most characters of a reason an earlier row keeps.
const why_limit = 120

// A state as a chip: its words as text, its class a literal from the closed
// type.
fn state_chip(state: State) -> Element(message) {
  html.span([attribute.class("trace-state"), state_class(state)], [
    html.text(trace_view.state_word(state)),
  ])
}

fn state_class(state: State) -> attribute.Attribute(message) {
  case state {
    Running -> attribute.class("trace-running")
    Completed -> attribute.class("trace-completed")
    Errored | Rejected | CompileFailed | RunFailed | Failed ->
      attribute.class("trace-failed")
  }
}
