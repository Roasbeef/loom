//// The admin page's Deployment section: the verdict on the owner's machines and
//// the table that lists them (protocol-change/085, the addendum of 2026-10-16).
////
//// The section follows People and Sessions. Its first line is the verdict
//// (`machines.verdict_words`): how many nodes the deployment has and how many of
//// them are degraded, down or not linked from here. Under it are, when they
//// apply, a line saying this daemon's copy of the session directory is
//// unconfirmed and a line naming what the daemon left out of the reply to fit one
//// frame. Then the table, one row for each machine: its name, roles, state,
//// platform, sandbox enforcement, toolchains, capacity, standing in the ledger and
//// the age of its last report.
////
//// ## A row is a button
////
//// The name in a row is a button that sends the message naming the machine the
//// server drew into the tree. The page then reads that machine and draws its page
//// under the table (`view/admin_machine`). The button is a click beneath the
//// admin body, which the admin socket already admits, so the section adds no
//// event class, scope or route.
////
//// ## A machine this daemon does not dial
////
//// A member of the ledger that this daemon's configuration does not hold is on
//// the list, marked "not linked from here" where the state pill would be. The
//// daemon never dials it, so the row has no state and no facts of a report: its
//// cells say they are not known from here, and the ledger's standing is stated.
////
//// ## What is drawn as what
////
//// Every name, key, node, platform, enforcement and toolchain is another daemon's
//// or the operator's text, drawn as a text node. The classes are complete fixed
//// literals, and the only ones chosen by the data are the pill tints
//// `machines.pill_class` returns for a closed type. A row is keyed by its place
//// in the list, so no name becomes a key.
////
//// ## Flow
////
//// `view` → `table` → `row`
////
//// 1. `view` draws the section from what the page holds of the deployment: the
////    verdict and the table, or the words for a deployment not yet read or one
////    that could not be.
//// 2. `table` draws the header and a `row` for each machine.
//// 3. `row` draws one machine, and its page when it is the chosen one is drawn by
////    `view/admin_machine` beneath the table.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/machines.{
  type Held, type Ledgered, type Machine, type Snapshot, Dialled, Enrolled,
  Failed, Findings, Known, NotLinkedFromHere, NotListed, NothingYet, This,
  Unconfirmed, Unledgered,
}

/// What the section is given.
pub type Section(message) {
  Section(
    /// What the page holds of the deployment.
    held: Held,
    /// The node of the chosen machine, if one is.
    chosen: Option(String),
    /// The message a row's name sends, given the node the row was drawn for.
    choose: fn(String) -> message,
    /// The chosen machine's page, drawn under the table, or nothing.
    page: Element(message),
  )
}

/// The section.
///
/// ## Examples
///
/// ```gleam
/// // admin_machines.view(Section(machines.NothingYet, None, choose, element.none()))
/// ```
pub fn view(section: Section(message)) -> Element(message) {
  html.section(
    [attribute.class("admin-section"), attribute.aria_label("Deployment")],
    case section.held {
      NothingYet -> [
        html.h2([attribute.class("home-heading")], [html.text("Deployment")]),
        html.p([attribute.class("home-empty")], [
          html.text("Reading the deployment."),
        ]),
      ]
      Failed(kept: None) -> [
        html.h2([attribute.class("home-heading")], [html.text("Deployment")]),
        html.p([attribute.class("home-empty")], [
          html.text("The deployment could not be read just now."),
        ]),
      ]
      Failed(kept: Some(snapshot)) ->
        list.append(drawn(snapshot, section), [
          html.p([attribute.class("admin-note")], [
            html.text(
              "The last read of the deployment failed. This is the one before it.",
            ),
          ]),
        ])
      Known(snapshot:) -> drawn(snapshot, section)
    },
  )
}

// The verdict, its notes, the table and the chosen machine's page.
fn drawn(
  snapshot: Snapshot,
  section: Section(message),
) -> List(Element(message)) {
  [
    html.h2([attribute.class("home-heading")], [
      html.text(machines.verdict_words(snapshot.machines)),
    ]),
    notes(snapshot),
    case snapshot.machines {
      [] ->
        html.p([attribute.class("home-empty")], [
          html.text("This daemon has no other machine configured."),
        ])
      [_, ..] -> table(snapshot.machines, section.chosen, section.choose)
    },
    section.page,
  ]
}

// The lines under the verdict: the directory copy when it is unconfirmed and
// what the daemon left out of the reply.
fn notes(snapshot: Snapshot) -> Element(message) {
  html.div(
    [attribute.class("admin-notes")],
    list.flatten([
      case snapshot.directory {
        Some(machines.Directory(copy: Some(Unconfirmed))) -> [
          html.p([attribute.class("admin-note")], [
            html.text(
              "This daemon could not confirm that its copy of the session directory is current.",
            ),
          ]),
        ]
        Some(_) | None -> []
      },
      case snapshot.omitted {
        [] -> []
        words -> [
          html.p([attribute.class("admin-note")], [
            html.text(
              "The daemon left out "
              <> string.join(words, ", ")
              <> " to fit the reply in one frame. Choose a machine to read its own.",
            ),
          ]),
        ]
      },
    ]),
  )
}

// The header and a row for each machine, in a box that scrolls sideways on a
// narrow screen so the columns keep their widths.
fn table(
  machines: List(Machine),
  chosen: Option(String),
  choose: fn(String) -> message,
) -> Element(message) {
  html.div([attribute.class("admin-machines-wrap")], [
    html.table([attribute.class("admin-machines")], [
      html.thead([], [
        html.tr(
          [],
          list.map(
            [
              "Name", "Roles", "State", "Platform", "Enforcement", "Toolchains",
              "Capacity", "Ledger", "Last report",
            ],
            fn(label) { html.th([attribute.scope("col")], [html.text(label)]) },
          ),
        ),
      ]),
      keyed.tbody(
        [],
        list.index_map(machines, fn(machine, index) {
          #(int.to_string(index), row(machine, chosen, choose))
        }),
      ),
    ]),
  ])
}

// One machine. Its name is the button.
fn row(
  machine: Machine,
  chosen: Option(String),
  choose: fn(String) -> message,
) -> Element(message) {
  let current = case chosen {
    Some(node) if node == machine.node -> [attribute.aria_current("true")]
    Some(_) | None -> []
  }
  html.tr(
    [attribute.class("admin-machine-row"), ..current],
    list.append(
      [
        html.td([], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("admin-pick"),
              event.on_click(choose(machine.node)),
            ],
            [
              html.span([attribute.class("admin-name")], [
                html.text(machine.name),
              ]),
              case machine.whose {
                This ->
                  html.span([attribute.class("admin-sub")], [
                    html.text("this daemon"),
                  ])
                machines.Other -> element.none()
              },
            ],
          ),
        ]),
        html.td([], [html.text(roles(machine))]),
        html.td([], [state(machine)]),
      ],
      facts(machine),
    ),
  )
}

fn roles(machine: Machine) -> String {
  string.join(list.map(machine.roles, machines.role_words), ", ")
}

// The state pill, or the words for a machine the daemon does not dial.
fn state(machine: Machine) -> Element(message) {
  case machine.here {
    Dialled(findings: Findings(state:, ..)) ->
      html.span(
        [attribute.class("pill"), attribute.class(machines.pill_class(state))],
        [html.text(machines.state_words(state))],
      )
    NotLinkedFromHere ->
      html.span([attribute.class("admin-sub")], [
        html.text("not linked from here"),
      ])
  }
}

// The cells that come from a report and from the ledger: platform, enforcement,
// toolchains, capacity, standing and the age of the last report. A machine that
// is not dialled has no report, and each of those cells is a dash.
fn facts(machine: Machine) -> List(Element(message)) {
  let executor = case machine.here {
    Dialled(findings: Findings(executor:, ..)) -> executor
    NotLinkedFromHere -> None
  }
  [
    cell(option.then(executor, fn(found) { found.platform })),
    cell(option.then(executor, fn(found) { found.enforcement })),
    cell(case executor {
      Some(machines.ExecutorFacts(toolchains: [_, ..] as found, ..)) ->
        Some(string.join(found, ", "))
      Some(_) | None -> None
    }),
    cell(capacity(machine)),
    cell(Some(standing(machine.ledgered))),
    cell(last_report(machine.ledgered)),
  ]
}

// A cell of text, or a dash for a fact that is not known.
fn cell(words: Option(String)) -> Element(message) {
  html.td([], [html.text(option.unwrap(words, "—"))])
}

// How full the machine is: an executor's open scopes out of the most it admits,
// an orchestrator's reserved runtimes out of its capacity.
fn capacity(machine: Machine) -> Option(String) {
  case machine.here {
    NotLinkedFromHere -> None
    Dialled(findings: Findings(executor:, orchestrator:, ..)) ->
      case executor, orchestrator {
        Some(machines.ExecutorFacts(scopes:, scope_limit:, ..)), None ->
          Some(
            int.to_string(scopes.open) <> " of " <> int.to_string(scope_limit),
          )
        None, Some(machines.OrchestratorFacts(occupied:, capacity:, ..)) ->
          Some(int.to_string(occupied) <> " of " <> int.to_string(capacity))
        Some(machines.ExecutorFacts(scopes:, scope_limit:, ..)),
          Some(machines.OrchestratorFacts(occupied:, capacity:, ..))
        ->
          Some(
            int.to_string(scopes.open)
            <> " of "
            <> int.to_string(scope_limit)
            <> " · "
            <> int.to_string(occupied)
            <> " of "
            <> int.to_string(capacity),
          )
        None, None -> None
      }
  }
}

/// The words for a machine's standing in the ledger, with its directory seat
/// when it has one.
///
/// ## Examples
///
/// ```gleam
/// assert admin_machines.standing(machines.NotListed) == "not listed"
/// ```
pub fn standing(ledgered: Ledgered) -> String {
  case ledgered {
    Enrolled(standing:) ->
      case standing.seat {
        machines.Voter -> "enrolled · voter"
        machines.Learner -> "enrolled · learner"
        machines.NoSeat -> "enrolled"
      }
    NotListed -> "not listed"
    Unledgered -> "no ledger"
  }
}

// How long ago the member reported its head to this daemon, or nothing when it
// has not or the machine is not in the ledger.
fn last_report(ledgered: Ledgered) -> Option(String) {
  case ledgered {
    Enrolled(standing: machines.Standing(age_ms: Some(age), ..)) ->
      Some(machines.age_words(age))
    Enrolled(..) -> Some("not reported")
    NotListed | Unledgered -> None
  }
}
