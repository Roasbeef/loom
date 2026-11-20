//// Draws what a session's brief says (`web_view/session_brief`) in the inbox's
//// reading pane: the agent's latest message, its last few steps, the peer
//// messages that reached it since it asked, the coordinator's goal and strands,
//// and the last command it ran.
////
//// The brief is bounded text that a model or another session wrote, so every
//// word of it is a text node under a label that says whose words they are, and
//// the label says `untrusted text`. The page's own words around it are fixed. A
//// time is an instant that the browser draws in its own zone
//// (`view/phrase`). The page never claims that a message is relevant to the
//// thread: a peer message is shown with who sent it and when, and a reader
//// decides. A step's outcome is the result's own report, and the last command is
//// stated as a fact with its exit status, never as the result of a check.
////
//// No attribute, class or key carries any of a brief's text. The classes are
//// complete literals, so Tailwind finds them. Every function here returns an
//// empty node for a section the brief does not have, so the caller places each
//// without testing for it.
////
//// ## Flow
////
//// `latest`, `steps`, `peers`, `coordinator` and `command` each draw one section
//// and share `view/inbox_parts`' frame.
////
//// 1. `latest` and `peers` are quotes: a source line over the words.
//// 2. `steps` is a monospace card of one line for each step.
//// 3. `coordinator` is a card of the goal, the delegates' counts and the tokens,
////    over one line for each strand.
//// 4. `command` is the pill that states the last command and its exit status.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/session_brief.{type Brief, type Command, type Peer, type Step}
import web_view/thread_words
import web_view/view/inbox_parts as parts
import web_view/view/phrase

/// The agent's latest message, which may belong to a turn that is still running,
/// under a label that says it is untrusted and when it was written. Nothing when
/// the brief has none.
///
/// ## Examples
///
/// ```gleam
/// // brief_view.latest(brief)
/// ```
pub fn latest(brief: Brief) -> Element(message) {
  case brief.assistant {
    Some(assistant) ->
      case string.trim(session_brief.untrusted_text(assistant.text)) {
        "" -> element.none()
        _ ->
          html.div([attribute.class("inbox-said")], [
            parts.quote_nodes(
              [
                html.text("The agent's latest message, untrusted text · "),
                phrase.clock(assistant.at),
              ],
              session_brief.untrusted_text(assistant.text),
            ),
          ])
      }
    None -> element.none()
  }
}

/// The agent's latest message as its own section, `Where it stopped`, for an
/// ask: the words the agent wrote before it asked. Nothing when the brief has no
/// message.
///
/// ## Examples
///
/// ```gleam
/// // brief_view.stopped(brief)
/// ```
pub fn stopped(brief: Brief) -> Element(message) {
  case brief.assistant {
    Some(assistant) ->
      case string.trim(session_brief.untrusted_text(assistant.text)) {
        "" -> element.none()
        _ -> parts.section("Where it stopped", [latest(brief)])
      }
    None -> element.none()
  }
}

/// The main strand's last finished message under a label that says it is not
/// current work, untrusted, and when the entry holding it was written, if the
/// activity read says. `text` is model text and a text node.
///
/// ## Examples
///
/// ```gleam
/// // brief_view.finished("Done.", Some(1_790_000_000_000))
/// ```
pub fn finished(text: String, at: Option(Int)) -> Element(message) {
  parts.quote_nodes(
    [
      html.text("The agent's last message, untrusted text"),
      case at {
        Some(instant) ->
          element.fragment([html.text(" · "), phrase.clock(instant)])
        None -> element.none()
      },
    ],
    text,
  )
}

/// The agent's last few steps as a monospace card: the time, the tool, the
/// step's words and how it stands, newest first as the brief holds them. The
/// outcome is the word `succeeded` in the added colour, `failed` in the danger
/// colour, or `running`; it is what the call's result reported and says nothing
/// of what the command meant.
///
/// ## Examples
///
/// ```gleam
/// // brief_view.steps(brief)
/// ```
pub fn steps(brief: Brief) -> Element(message) {
  case brief.steps {
    [] -> element.none()
    listed ->
      parts.section("Last few steps", [
        parts.card([
          html.ul(
            [attribute.class("brief-steps")],
            list.map(listed, fn(each) { html.li([], step(each)) }),
          ),
        ]),
      ])
  }
}

/// One step's line.
fn step(each: Step) -> List(Element(message)) {
  [
    html.span([attribute.class("brief-time")], [phrase.clock(each.at)]),
    html.span([attribute.class("brief-tool")], [
      html.text(session_brief.untrusted_text(each.tool)),
    ]),
    html.span([attribute.class("brief-words")], [
      html.text(session_brief.untrusted_text(each.words)),
    ]),
    case each.outcome {
      session_brief.Succeeded ->
        html.span([attribute.class("brief-ok")], [html.text("succeeded")])
      session_brief.Failed ->
        html.span([attribute.class("brief-bad")], [html.text("failed")])
      session_brief.Running ->
        html.span([attribute.class("brief-run")], [html.text("running")])
    },
  ]
}

/// The peer messages that reached the session after the time the read named, as
/// dashed quotes under the label `In this session since it asked`. Each says
/// that it is a peer message, which session and strand sent it, when, and that
/// it is untrusted text. `name_of` words a session's identity as the page does.
/// The page draws them and claims nothing about whether they bear on the
/// thread. Nothing when there are none.
///
/// ## Examples
///
/// ```gleam
/// // brief_view.peers(brief.peers, name_of)
/// ```
pub fn peers(
  listed: List(Peer),
  name_of: fn(String) -> String,
) -> Element(message) {
  case listed {
    [] -> element.none()
    _ ->
      parts.section(
        "In this session since it asked",
        list.map(listed, fn(each) { peer(each, name_of) }),
      )
  }
}

/// One peer message.
fn peer(each: Peer, name_of: fn(String) -> String) -> Element(message) {
  parts.quote_nodes(
    [
      html.b([], [html.text("Peer message")]),
      html.text(
        " · "
        <> name_of(each.session)
        <> " · "
        <> each.strand
        <> " messaged this session at ",
      ),
      phrase.clock(each.at),
      html.text(" · untrusted text"),
    ],
    session_brief.untrusted_text(each.text),
  )
}

/// The coordinator's card: the goal's objective and status, the delegates'
/// counts, the tokens spent of the budget, and a line for each delegate with its
/// state and the time it began. A delegate is a strand other than `main`, which
/// is the session's own and says nothing a thread does not already say.
/// Nothing when the session has neither a goal nor a delegate. The objective and
/// the strands' names are text a person or a session chose, drawn as text nodes.
///
/// ## Examples
///
/// ```gleam
/// // brief_view.coordinator(brief)
/// ```
pub fn coordinator(brief: Brief) -> Element(message) {
  let delegates = list.filter(brief.strands, fn(each) { each.name != "main" })

  // A session with no goal and no delegate has no coordinator to draw.
  case brief.goal, delegates {
    None, [] -> element.none()
    goal, _ ->
      parts.section("The coordinator", [
        parts.card(
          list.flatten([
            [
              html.div([attribute.class("brief-ctx")], context(goal, delegates)),
            ],
            case delegates {
              [] -> []
              _ -> [
                html.ul(
                  [attribute.class("brief-strands")],
                  list.map(delegates, strand),
                ),
              ]
            },
          ]),
        ),
      ])
  }
}

/// The card's three columns: the goal, the delegates and the tokens. A column
/// whose data is absent is left out.
fn context(
  goal: Option(session_brief.Goal),
  strands: List(session_brief.Strand),
) -> List(Element(message)) {
  list.flatten([
    case goal {
      Some(held) -> [
        column(
          "Goal",
          held.objective,
          case thread_words.goal_status(held.status) {
            Some(words) -> words
            None -> ""
          },
        ),
      ]
      None -> []
    },
    case strands {
      [] -> []
      _ -> [column("Delegates", thread_words.delegates(strands), "")]
    },
    case goal {
      Some(held) if held.token_budget > 0 -> [
        column(
          "Tokens",
          thread_words.tokens(held.tokens_used)
            <> " of "
            <> thread_words.tokens(held.token_budget),
          "",
        ),
      ]
      Some(_) | None -> []
    },
  ])
}

/// One column: a quiet label, the value in bold and a quiet line under it when
/// there is one.
fn column(label: String, value: String, note: String) -> Element(message) {
  html.div([], [
    html.span([attribute.class("brief-label")], [html.text(label)]),
    html.b([], [html.text(value)]),
    case note {
      "" -> element.none()
      words -> html.span([attribute.class("brief-note")], [html.text(words)])
    },
  ])
}

/// One strand's line: its name and what it is doing, with the time it began. A
/// stopped strand is in the danger colour.
fn strand(each: session_brief.Strand) -> Element(message) {
  html.li([], [
    html.span(
      [
        attribute.class("brief-strand"),
        case each.state {
          session_brief.Stopped -> attribute.class("brief-bad")
          session_brief.Working | session_brief.Idle -> attribute.none()
        },
      ],
      [html.text(each.name)],
    ),
    html.span(
      [],
      phrase.view(thread_words.strand_phrase(each.state, each.since)),
    ),
  ])
}

/// The pill that states the last command and how it ended: `last command: make
/// check-core, exit 0`. It is a fact about a call that ran, not a claim that a
/// check passed. The command is text the model chose, a text node. Nothing when
/// no command ran.
///
/// ## Examples
///
/// ```gleam
/// // brief_view.command(brief.command)
/// ```
pub fn command(command: Option(Command)) -> Element(message) {
  case command {
    Some(ran) ->
      html.span([attribute.class("inbox-pill brief-command")], [
        html.text(
          "last command: "
          <> session_brief.untrusted_text(ran.command)
          <> ", exit "
          <> int.to_string(ran.exit),
        ),
      ])
    None -> element.none()
  }
}
