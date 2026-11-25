//// An Updates session as a card that says what it is doing now.
////
//// The inbox's Updates group lists sessions that are working with nothing asked
//// of the owner. A two-line row says little about a running session, so the group
//// draws each as a card, and the "Watch all" board draws the same card in a grid
//// in the reading pane (`view/inbox`). The card shows what the reading pane's
//// update thread already reads: the session's name, what it is doing and how long
//// the turn has gone on, the agent's latest message, the step that is running, one
//// compact line for its strands, a failed last command and the machine it runs on
//// when that is not this one, and the way to watch it live. Opening the disclosure
//// adds the whole message, the last few steps with how each stands, the strands and
//// the last command with its exit.
////
//// Every word that a model, a peer or the host wrote is a text node under a label
//// that says it is untrusted: the message, a step's tool and words, a strand's
//// name, a command, a machine's name. None reaches an attribute, a class or a key
//// (protocol-change/051). The card holds no state: whether it is open is the
//// page's (`Density`), and the brief behind it is read by the page for the
//// sessions in Updates alone, a few steps each.
////
//// ## Flow
////
//// `view` draws the card from its parts: `head`, `said`, `running`, `compact`,
//// then `more` when the card is open, and `actions`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/inbox_rule.{type Thread}
import web_view/session_brief.{type Brief, type Step}
import web_view/sessions.{type Glance}
import web_view/view/inbox_parts as parts

/// How much of the card is drawn.
pub type Density {
  /// The head, the message cut to three lines, the running step and one line.
  Collapsed

  /// Everything the card holds: the whole message, the last few steps, the
  /// strands and the last command.
  Expanded
}

/// How many steps an expanded card, and so the board's, draws. The brief holds
/// no more than the daemon's own bound, and a card never draws more than this.
pub const expanded_steps = 5

/// What a card draws and the messages its buttons send.
pub type Card(message) {
  Card(
    /// The session, as the inbox's list holds it.
    thread: Thread,
    /// What the session is doing and for how long, in the words the reading pane's
    /// eyebrow uses (`working, 14 min into a turn`), or nothing when the data holds
    /// no turn time.
    state: Option(String),
    /// How long the turn has gone on, as the row's age says it.
    age: Option(parts.Age),
    /// The brief the page read of the session, or nothing before the first read.
    brief: Option(Brief),
    /// The executor the session's workspace is on when it is not this machine.
    machine: Option(String),
    /// Whether the person has opened this session's thread since the page loaded.
    reading: parts.Reading,
    /// How much of the card is drawn.
    density: Density,
    /// What a press on the card's head sends: show the session's thread.
    pick: message,
    /// What "Watch live" sends: open the session's page.
    open: message,
    /// What the disclosure sends: open or close this card.
    toggle: message,
  )
}

/// The card: its head, the agent's latest message cut to three lines and marked
/// untrusted, the step that is running, one compact line, and the buttons.
///
/// ## Examples
///
/// ```gleam
/// // update_card.view(Card(thread:, state: None, age: None, brief: None, machine: None, reading: parts.Unread, density: update_card.Collapsed, pick:, open:, toggle:))
/// ```
pub fn view(card: Card(message)) -> Element(message) {
  let thread = card.thread

  html.article(
    [
      attribute.class("upd-card"),
      case card.density {
        Collapsed -> attribute.none()
        Expanded -> attribute.class("upd-open")
      },
      case card.reading {
        parts.Unread -> attribute.none()
        parts.Read -> attribute.class("upd-seen")
      },
    ],
    [
      head(card),
      said(card),
      running(card.brief),
      compact(card),
      case card.density {
        Collapsed -> element.none()
        Expanded -> more(thread, card.brief)
      },
      actions(card),
    ],
  )
}

/// The head: the session's name and what it is doing, and how long, as one press
/// that shows its thread.
fn head(card: Card(message)) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("upd-head"),
      event.on_click(card.pick),
    ],
    [
      html.span([attribute.class("upd-title")], [
        html.text(inbox_rule.shown_name(card.thread)),
      ]),
      html.span([attribute.class("upd-state")], [
        html.text(option.unwrap(card.state, "working")),
      ]),
      case card.age {
        Some(parts.Age(words:, ..)) ->
          html.span([attribute.class("upd-age")], [html.text(words)])
        None -> element.none()
      },
    ],
  )
}

/// The agent's latest message under the words that say whose they are. Before the
/// brief is read the session's last finished message stands in, which is the head
/// the row used to say.
fn said(card: Card(message)) -> Element(message) {
  // The brief's latest text wins; the stand-in is only for a card not yet read.
  let words = case card.brief {
    Some(session_brief.Brief(assistant: Some(latest), ..)) ->
      session_brief.untrusted_text(latest.text)
    Some(_) | None -> inbox_rule.thread_head(card.thread)
  }

  html.p([attribute.class("upd-said")], [
    html.span([attribute.class("upd-src")], [
      html.text("latest message, untrusted text"),
    ]),
    html.span([attribute.class("upd-text")], [html.text(words)]),
  ])
}

/// The step that is running, or the newest one when none is: the tool and what it
/// was given. Nothing before the brief holds a step.
fn running(brief: Option(Brief)) -> Element(message) {
  // A card whose brief is not read has no steps.
  let steps = case brief {
    Some(held) -> held.steps
    None -> []
  }

  // A call with no result yet is the one running; otherwise the newest step.
  let found = case
    list.find(steps, fn(each) { each.outcome == session_brief.Running })
  {
    Ok(live) -> Some(live)
    Error(Nil) -> option.from_result(list.first(steps))
  }

  // Nothing is drawn for a session with no step yet.
  case found {
    Some(each) -> html.p([attribute.class("upd-step")], step_line(each))
    None -> element.none()
  }
}

/// One step as the tool, what it was given and how it stands.
fn step_line(each: Step) -> List(Element(message)) {
  [
    html.span([attribute.class("upd-tool")], [
      html.text(session_brief.untrusted_text(each.tool)),
    ]),
    html.span([attribute.class("upd-words")], [
      html.text(session_brief.untrusted_text(each.words)),
    ]),
    html.span([attribute.class(outcome_class(each.outcome))], [
      html.text(outcome_words(each.outcome)),
    ]),
  ]
}

/// The class that colours a step's outcome.
fn outcome_class(outcome: session_brief.Outcome) -> String {
  case outcome {
    session_brief.Running -> "upd-run"
    session_brief.Succeeded -> "upd-ok"
    session_brief.Failed -> "upd-bad"
  }
}

/// The words a step's outcome is drawn as.
fn outcome_words(outcome: session_brief.Outcome) -> String {
  case outcome {
    session_brief.Running -> "running"
    session_brief.Succeeded -> "ok"
    session_brief.Failed -> "failed"
  }
}

/// One compact line: how many strands the session has and how they stand, a last
/// command that failed, and the machine when it is not this one. A card with none
/// of these draws no line.
fn compact(card: Card(message)) -> Element(message) {
  let pieces =
    list.flatten([
      strand_counts(card.brief),
      failed_command(card.brief),
      case card.machine {
        Some(name) -> ["on " <> name]
        None -> []
      },
    ])

  // A card with none of the three pieces draws no line.
  case pieces {
    [] -> element.none()
    [_, ..] ->
      html.p([attribute.class("upd-line")], [
        html.text(string.join(pieces, " · ")),
      ])
  }
}

/// The delegates a session has, counted by how they stand. The session's own
/// strand and the advisor are not delegates, so a session that delegated nothing
/// has no such piece. It needs the brief; before the brief is read there is
/// nothing to count.
fn strand_counts(brief: Option(Brief)) -> List(String) {
  // Only a read brief says how the strands stand.
  case brief {
    Some(held) -> {
      let others =
        list.filter(held.strands, fn(each) {
          each.name != "main" && each.name != "advisor"
        })
      let in_state = fn(which) {
        list.count(others, fn(each) { each.state == which })
      }

      // A session that delegated nothing has no piece to draw.
      case others {
        [] -> []
        [_, ..] -> [
          int.to_string(list.length(others))
          <> case others {
            [_] -> " strand: "
            _ -> " strands: "
          }
          <> int.to_string(in_state(session_brief.Working))
          <> " working, "
          <> int.to_string(in_state(session_brief.Stopped))
          <> " stopped",
        ]
      }
    }
    None -> []
  }
}

/// The last shell command when it failed, as a fact and not a verdict.
fn failed_command(brief: Option(Brief)) -> List(String) {
  case brief {
    Some(session_brief.Brief(command: Some(ran), ..)) if ran.exit != 0 -> [
      "last command exit "
      <> int.to_string(ran.exit)
      <> ": "
      <> session_brief.untrusted_text(ran.command),
    ]
    Some(_) | None -> []
  }
}

/// What the disclosure adds: the last few steps with how each stands, the strands
/// with what they are doing, and the last command with its exit.
fn more(thread: Thread, brief: Option(Brief)) -> Element(message) {
  // A card whose brief is not read opens on an empty one.
  let held = case brief {
    Some(read) -> read
    None -> empty_brief()
  }

  html.div([attribute.class("upd-more")], [
    // The steps, newest first, cut to the card's bound.
    case list.take(held.steps, expanded_steps) {
      [] -> element.none()
      listed ->
        html.ul(
          [attribute.class("upd-steps")],
          list.map(listed, fn(each) { html.li([], step_line(each)) }),
        )
    },
    strand_list(held, thread.report.glances),
    // The last command with its exit, whether or not it failed.
    case held.command {
      Some(ran) ->
        html.p([attribute.class("upd-last")], [
          html.text(
            "last command: "
            <> session_brief.untrusted_text(ran.command)
            <> ", exit "
            <> int.to_string(ran.exit),
          ),
        ])
      None -> element.none()
    },
  ])
}

/// The strands one to a line: each delegate's name and how it stands, and what the
/// strands say they are doing.
fn strand_list(held: Brief, glances: List(Glance)) -> Element(message) {
  let lines =
    list.append(
      list.filter_map(held.strands, fn(each) {
        case each.name {
          "main" | "advisor" -> Error(Nil)
          name -> Ok(name <> ": " <> state_words(each.state))
        }
      }),
      list.map(glances, glance_line),
    )

  // A session with no strand to name draws no list.
  case lines {
    [] -> element.none()
    [_, ..] ->
      html.ul(
        [attribute.class("upd-strands")],
        list.map(lines, fn(line) { html.li([], [html.text(line)]) }),
      )
  }
}

/// How a strand stands, in a word.
fn state_words(state: session_brief.State) -> String {
  case state {
    session_brief.Working -> "working"
    session_brief.Idle -> "idle"
    session_brief.Stopped -> "stopped"
  }
}

/// A glance as one line: the title the strand chose, or its name, then the
/// summary.
fn glance_line(glance: Glance) -> String {
  case glance.title {
    "" -> glance.strand <> ": " <> glance.summary
    title -> title <> ": " <> glance.summary
  }
}

/// A brief with nothing in it, for a card whose brief has not been read.
fn empty_brief() -> Brief {
  session_brief.Brief(
    assistant: None,
    steps: [],
    strands: [],
    goal: None,
    peers: [],
    command: None,
  )
}

/// The buttons: "Watch live" opens the session's page, and the disclosure opens
/// and closes the card. `aria-expanded` says which, in the two fixed words.
fn actions(card: Card(message)) -> Element(message) {
  html.div([attribute.class("upd-acts")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("upd-watch"),
        event.on_click(card.open),
      ],
      [html.text("Watch live ›")],
    ),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("upd-toggle"),
        attribute.attribute("aria-expanded", case card.density {
          Collapsed -> "false"
          Expanded -> "true"
        }),
        event.on_click(card.toggle),
      ],
      [
        html.text(case card.density {
          Collapsed -> "Expand ▾"
          Expanded -> "Collapse ▴"
        }),
      ],
    ),
  ])
}
