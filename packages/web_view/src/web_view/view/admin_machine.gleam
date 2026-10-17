//// One machine's page on the admin page (protocol-change/085, the addendum of
//// 2026-10-16): a header, four tabs, and under the chosen tab what the owner needs
//// to know and the commands that change it.
////
//// The page reads and runs nothing of its own. There is no terminal, and no
//// button enrolls, renews, revokes or releases anything. Those commands sign
//// ledger entries with a key that is on the operator's machine, or open an
//// executor's ledger with its daemon stopped, so the Access tab states the exact
//// command in a box that copies it (`web_view/operator_commands`) and the operator
//// runs it in a terminal on the right machine. The only controls are the tab
//// buttons and Close, and each is a click beneath the admin body.
////
//// ## The four tabs
////
//// - **Overview**: the machine's health with the fixed reasons, its build, protocol
////   and uptime, how this daemon is linked to it, and the relations the daemon
////   reported.
//// - **Sessions**: the sessions this daemon's catalogue places on the machine, the
////   count each orchestrator places there, and the sessions another
////   orchestrator lists as placed there, grouped by that orchestrator.
//// - **Access**: the machine's place in the membership ledger, the certificate
////   pin its peers hold, its links, and the commands. A node the ledger does not
////   list is shown the `enroll` command instead of `renew` and `revoke`.
//// - **Activity**: the scope counts, the scopes that block a reopen and the moves
////   in flight with their phase, stall time and reason.
////
//// ## A machine this daemon does not dial
////
//// A ledger member that is not linked from here has only its ledger row: its
//// Overview says the daemon does not connect to it, its Sessions and Activity
//// tabs say there is nothing to read, and its Access tab is complete.
////
//// ## What is drawn as what
////
//// Every name, node, key, pin, session identity, reason and path is drawn as a text
//// node. The commands travel in the `<loom-copy>` element's `text` attribute,
//// which the element checks against the operator-command grammar before it
//// offers a button (`web_client/copy_rule`), and a name that cannot be written
//// into a command safely gets no box (`operator_commands.quote`). The classes
//// are complete fixed literals, and the only ones chosen by data are the pill
//// tints of a closed type.
////
//// ## Flow
////
//// `view` → `header` → `tabs` → `overview` | `sessions` | `access` | `activity`
////
//// 1. `view` draws the header and the tab bar, and the body of the chosen tab.
//// 2. Each body is its own function and reads only what the page holds: the
////    machine, the snapshot, the machine's long lists, the local catalogue and
////    what the other orchestrators listed.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/elsewhere.{type Group}
import web_view/machines.{
  type Detailed, type Findings, type Machine, type Snapshot, type Tab,
  type Unclean, Awaiting, Detailed, Dialled, Enrolled, NotLinkedFromHere,
  NotListed, Unledgered, Withheld,
}
import web_view/operator_commands
import web_view/sessions.{type Entry}
import web_view/view/heading

/// The most local sessions a tab lists before it counts the rest.
pub const rows_drawn = 50

/// What the page is given.
pub type Page(message) {
  Page(
    /// The chosen machine.
    machine: Machine,
    /// The deployment it is part of.
    snapshot: Snapshot,
    /// The machine's long lists, or why the page has none.
    detail: Detailed,
    /// The chosen tab.
    tab: Tab,
    /// The owner's sessions in this daemon's catalogue.
    entries: List(Entry),
    /// What the other orchestrators listed, once they have been read.
    peers: Option(List(Group)),
    /// The message a tab button sends, given the tab.
    pick: fn(Tab) -> message,
    /// The message Close sends.
    close: message,
  )
}

/// The machine's page.
///
/// ## Examples
///
/// ```gleam
/// // admin_machine.view(Page(machine, snapshot, None, machines.OverviewTab, [], None, pick, close))
/// ```
pub fn view(page: Page(message)) -> Element(message) {
  html.section(
    [attribute.class("admin-machine"), attribute.aria_label("Machine")],
    [
      header(page),
      html.div(
        [attribute.class("admin-tabs"), attribute.role("tablist")],
        list.map(machines.tabs, tab_button(_, page)),
      ),
      html.div([attribute.class("admin-tabpanel"), attribute.role("tabpanel")], [
        case page.tab {
          machines.OverviewTab -> overview(page)
          machines.SessionsTab -> sessions_tab(page)
          machines.AccessTab -> access(page)
          machines.ActivityTab -> activity(page)
        },
      ]),
    ],
  )
}

// The name, the state and Close, and under them the node and the roles.
fn header(page: Page(message)) -> Element(message) {
  let machine = page.machine
  html.div([attribute.class("admin-machine-head")], [
    html.div([attribute.class("admin-machine-title")], [
      html.h3([attribute.class("admin-subheading")], [html.text(machine.name)]),
      case machines.state_of(machine) {
        Some(state) ->
          html.span(
            [
              attribute.class("pill"),
              attribute.class(machines.pill_class(state)),
            ],
            [html.text(machines.state_words(state))],
          )
        None ->
          html.span([attribute.class("admin-sub")], [
            html.text("not linked from here"),
          ])
      },
      html.button(
        [
          attribute.type_("button"),
          attribute.class("admin-act"),
          event.on_click(page.close),
        ],
        [html.text("Close")],
      ),
    ]),
    html.p([attribute.class("admin-sub")], [
      html.text(
        machine.node
        <> " · "
        <> string.join(list.map(machine.roles, machines.role_words), ", "),
      ),
    ]),
  ])
}

// One tab's button. The chosen tab says so with `aria-selected`.
fn tab_button(tab: Tab, page: Page(message)) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("admin-tab"),
      attribute.role("tab"),
      attribute.aria_selected(tab == page.tab),
      event.on_click(page.pick(tab)),
    ],
    [html.text(machines.tab_words(tab))],
  )
}

// A line of quiet text.
fn line(words: String) -> Element(message) {
  html.p([attribute.class("admin-sub")], [html.text(words)])
}

// One labelled fact.
fn fact(label: String, value: Element(message)) -> List(Element(message)) {
  [
    html.dt([attribute.class("admin-fact-label")], [html.text(label)]),
    html.dd([attribute.class("admin-fact")], [value]),
  ]
}

fn words(text: String) -> Element(message) {
  html.text(text)
}

// The machine's long lists, when its read has answered.
fn long(page: Page(message)) -> Option(machines.Detail) {
  case page.detail {
    Detailed(detail:) -> Some(detail)
    Awaiting | Withheld -> None
  }
}

// The findings of a dialled machine, or nothing for one that is not.
fn findings(machine: Machine) -> Option(Findings) {
  case machine.here {
    Dialled(findings:) -> Some(findings)
    NotLinkedFromHere -> None
  }
}

// --- overview -------------------------------------------------------------------

fn overview(page: Page(message)) -> Element(message) {
  let machine = page.machine
  case findings(machine) {
    None ->
      html.div([], [
        line(
          "This daemon is not linked to this machine and does not connect to it. The membership ledger lists it, so its standing is on the Access tab.",
        ),
      ])
    Some(found) ->
      html.div([], [
        html.dl(
          [attribute.class("admin-facts")],
          list.flatten([
            fact("State", health(found)),
            fact("Build", words(build(found))),
            fact("Protocol", words(option_int(found.protocol))),
            fact("Up for", words(uptime(found))),
            fact("Link from this daemon", words(link_words(machine))),
            fact("Relations", relations(machine, page.snapshot)),
            fact("Last report", words(last_report(machine))),
            case long(page) {
              Some(machines.Detail(workspaces: [_, ..] as listed, ..)) ->
                fact("Workspaces", words(string.join(listed, ", ")))
              Some(_) | None -> []
            },
          ]),
        ),
        case found.executor {
          Some(machines.ExecutorFacts(contradiction: Some(contradiction), ..)) ->
            html.p([attribute.class("home-card-fact warn")], [
              html.text(contradiction),
            ])
          Some(_) | None -> element.none()
        },
        case page.detail, machine.whose {
          Awaiting, machines.Other -> line("Reading this machine.")
          Withheld, machines.Other ->
            line(
              "The daemon could not read this machine's long lists just now.",
            )
          Detailed(..), _ | _, machines.This -> element.none()
        },
      ])
  }
}

// The state with the daemon's fixed reasons beside it, each in a sentence.
fn health(found: Findings) -> Element(message) {
  html.div([], [
    html.span(
      [
        attribute.class("pill"),
        attribute.class(machines.pill_class(found.state)),
      ],
      [html.text(machines.state_words(found.state))],
    ),
    case found.state, found.why {
      machines.Down, Some(why) ->
        html.p([attribute.class("admin-sub")], [
          html.text(why <> ": " <> machines.reason_words(why)),
        ])
      _, _ -> element.none()
    },
    case found.reasons {
      [] -> element.none()
      listed ->
        html.ul(
          [attribute.class("admin-reasons")],
          list.map(listed, fn(reason) {
            html.li([attribute.class("admin-sub")], [
              html.text(reason <> ": " <> machines.reason_words(reason)),
            ])
          }),
        )
    },
  ])
}

fn build(found: Findings) -> String {
  case found.build_version, found.build_commit {
    Some(version), Some(commit) -> version <> " (" <> commit <> ")"
    Some(version), None -> version
    None, Some(commit) -> commit
    None, None -> "—"
  }
}

fn option_int(value: Option(Int)) -> String {
  case value {
    Some(number) -> int.to_string(number)
    None -> "—"
  }
}

fn uptime(found: Findings) -> String {
  case found.uptime_ms {
    Some(ms) -> machines.uptime_words(ms)
    None -> "—"
  }
}

fn link_words(machine: Machine) -> String {
  case machine.whose, machine.link {
    machines.This, _ -> "this daemon"
    machines.Other, machines.Linked -> "connected"
    machines.Other, machines.Unlinked -> "not connected"
    machines.Other, machines.Unobserved -> "—"
  }
}

fn last_report(machine: Machine) -> String {
  case machine.ledgered {
    Enrolled(machines.Standing(age_ms: Some(age), ..)) ->
      machines.age_words(age)
    Enrolled(..) -> "not reported"
    NotListed | Unledgered -> "—"
  }
}

// The relations the daemon reported that touch the machine, one to a line, with
// the other end named as the daemon names it.
fn relations(machine: Machine, snapshot: Snapshot) -> Element(message) {
  case
    list.filter(snapshot.edges, fn(each) {
      each.from == machine.node || each.to == machine.node
    })
  {
    [] -> html.text("—")
    touching ->
      html.ul(
        [attribute.class("admin-reasons")],
        list.map(touching, fn(each) {
          html.li([attribute.class("admin-sub")], [
            html.text(relation_words(machine, each, snapshot)),
          ])
        }),
      )
  }
}

fn relation_words(
  machine: Machine,
  edge: machines.Edge,
  snapshot: Snapshot,
) -> String {
  let from_here = edge.from == machine.node
  let other = case from_here {
    True -> name_of(snapshot, edge.to)
    False -> name_of(snapshot, edge.from)
  }
  case edge.relation, from_here {
    machines.Serves(sessions:), True ->
      "places " <> plural(sessions, "session") <> " on " <> other
    machines.Serves(sessions:), False ->
      other <> " places " <> plural(sessions, "session") <> " here"
    machines.Peers, _ -> "peer orchestrator " <> other
    machines.Members, _ -> "directory member with " <> other
  }
}

fn plural(count: Int, noun: String) -> String {
  case count {
    1 -> "1 " <> noun
    _ -> int.to_string(count) <> " " <> noun <> "s"
  }
}

// The name the daemon gives a node, or the node itself when it gives none.
fn name_of(snapshot: Snapshot, node: String) -> String {
  case list.find(snapshot.machines, fn(each) { each.node == node }) {
    Ok(found) -> found.name
    Error(Nil) -> node
  }
}

// --- sessions -------------------------------------------------------------------

fn sessions_tab(page: Page(message)) -> Element(message) {
  let machine = page.machine
  case machine.here {
    NotLinkedFromHere ->
      line(
        "This daemon does not connect to this machine, so it has nothing to say about its sessions.",
      )
    Dialled(..) ->
      html.div([], [
        html.h4([attribute.class("admin-subheading")], [
          html.text("In this daemon's catalogue"),
        ]),
        local(page),
        placed(page),
        elsewhere_rows(page),
      ])
  }
}

// The owner's sessions whose workspace is registered on this machine: the ones
// with no executor for this daemon itself, and the ones that name the machine's
// key for any other.
fn local(page: Page(message)) -> Element(message) {
  let held =
    list.filter(page.entries, fn(entry) {
      case page.machine.whose, entry.executor {
        machines.This, None -> True
        machines.This, Some(_) -> False
        machines.Other, Some(key) -> key == page.machine.name
        machines.Other, None -> False
      }
    })
  case held {
    [] -> line("No session of this daemon's catalogue is placed here.")
    [_, ..] ->
      html.div([], [
        line(plural(list.length(held), "session") <> "."),
        html.ul(
          [attribute.class("admin-list")],
          list.map(list.take(held, rows_drawn), fn(entry) {
            html.li([attribute.class("admin-row")], [
              html.div([attribute.class("admin-text")], [
                html.span([attribute.class("admin-name")], [
                  html.text(sessions.label(entry)),
                ]),
                html.span([attribute.class("admin-sub")], [
                  html.text(
                    heading.shorten_path(entry.workspace)
                    <> " · "
                    <> residency_words(entry.residency),
                  ),
                ]),
              ]),
            ])
          }),
        ),
        case list.length(held) > rows_drawn {
          True ->
            line(
              "and "
              <> int.to_string(list.length(held) - rows_drawn)
              <> " more.",
            )
          False -> element.none()
        },
      ])
  }
}

fn residency_words(residency: sessions.Residency) -> String {
  case residency {
    sessions.Live -> "running"
    sessions.Saved -> "saved"
    sessions.Blocked -> "needs attention"
    sessions.Moving(to:) -> "moving to " <> to
  }
}

// How many sessions each orchestrator places here, or, for an orchestrator, how
// many it places on each executor, from what the daemon reported.
fn placed(page: Page(message)) -> Element(message) {
  let machine = page.machine
  let serving =
    list.filter_map(page.snapshot.edges, fn(each) {
      case each.relation {
        machines.Serves(sessions:) if each.to == machine.node ->
          Ok(
            name_of(page.snapshot, each.from)
            <> " places "
            <> plural(sessions, "session")
            <> " here.",
          )
        machines.Serves(..) | machines.Peers | machines.Members -> Error(Nil)
      }
    })
  let on_executors = case long(page) {
    Some(machines.Detail(placements:, ..)) ->
      list.map(placements, fn(each) {
        "On "
        <> name_of(page.snapshot, each.executor_node)
        <> ": "
        <> int.to_string(each.resident)
        <> " running, "
        <> int.to_string(each.saved)
        <> " saved."
      })
    None -> []
  }
  case list.append(serving, on_executors) {
    [] -> element.none()
    lines ->
      html.div([], [
        html.h4([attribute.class("admin-subheading")], [
          html.text("As the orchestrators count them"),
        ]),
        html.ul(
          [attribute.class("admin-reasons")],
          list.map(lines, fn(each) {
            html.li([attribute.class("admin-sub")], [html.text(each)])
          }),
        ),
      ])
  }
}

// The sessions another orchestrator lists as placed on this machine, under that
// orchestrator's name. The node a row names is matched against the machine's, so
// two orchestrators that key an executor differently still attribute its rows to
// the same machine.
fn elsewhere_rows(page: Page(message)) -> Element(message) {
  case page.peers {
    None ->
      html.div([], [
        html.h4([attribute.class("admin-subheading")], [
          html.text("On other orchestrators"),
        ]),
        line("Reading the other orchestrators."),
      ])
    Some([]) -> element.none()
    Some(groups) ->
      html.div([], [
        html.h4([attribute.class("admin-subheading")], [
          html.text("On other orchestrators"),
        ]),
        ..list.map(groups, group(_, page.machine))
      ])
  }
}

fn group(each: Group, machine: Machine) -> Element(message) {
  case each.hearing {
    elsewhere.Silent -> line(each.name <> " did not answer.")
    elsewhere.Answered(rows:, more:) ->
      case
        list.filter(rows, fn(row) { row.executor_node == Some(machine.node) })
      {
        [] ->
          line(case more {
            elsewhere.Further ->
              each.name <> " lists none here on its first page."
            elsewhere.Last -> each.name <> " lists none here."
          })
        held ->
          html.div([], [
            line(
              each.name
              <> " lists "
              <> plural(list.length(held), "session")
              <> ":",
            ),
            html.ul(
              [attribute.class("admin-list")],
              list.map(held, fn(row) {
                html.li([attribute.class("admin-row")], [
                  html.div([attribute.class("admin-text")], [
                    html.span([attribute.class("admin-name")], [
                      html.text(row.name),
                    ]),
                    html.span([attribute.class("admin-sub")], [
                      html.text(
                        elsewhere.word(row.status) <> " · " <> row.workspace,
                      ),
                    ]),
                  ]),
                ])
              }),
            ),
          ])
      }
  }
}

// --- access ---------------------------------------------------------------------

fn access(page: Page(message)) -> Element(message) {
  let machine = page.machine
  html.div([], [
    case machine.ledgered {
      Enrolled(standing:) -> enrolled(page, standing)
      NotListed -> not_listed(page)
      Unledgered ->
        line(
          "This daemon runs without a membership ledger, so there is nothing to enroll, renew or revoke from here.",
        )
    },
    release_lines(page),
  ])
}

fn enrolled(
  page: Page(message),
  standing: machines.Standing,
) -> Element(message) {
  let head = case page.snapshot.ledger {
    Some(machines.Ledger(head_seq:, ..)) ->
      Some(" of " <> int.to_string(head_seq))
    None -> None
  }
  html.div([], [
    html.dl(
      [attribute.class("admin-facts")],
      list.flatten([
        fact("Listed as", words(standing.name)),
        fact("Role", words(machines.role_words(standing.role))),
        fact("Directory seat", words(seat_words(standing.seat))),
        fact(
          "Head reported",
          words(reported(standing.reported_seq, head, standing.age_ms)),
        ),
        fact("Certificate pin", case standing.pin {
          Some(pin) ->
            html.code([attribute.class("admin-id")], [html.text(pin)])
          None -> html.text("not stated by this daemon")
        }),
        fact(
          "Linked to",
          words(case standing.links {
            [] -> "none"
            listed -> string.join(listed, ", ")
          }),
        ),
      ]),
    ),
    html.p([attribute.class("admin-sub")], [
      html.text(
        "This page runs none of these. Copy a command and run it in a terminal on the machine that holds the authority key.",
      ),
    ]),
    command_box(
      "Renew its certificate",
      operator_commands.renew(standing.name),
      standing.name,
    ),
    line(
      "A node installed under a custom directory also needs --bundle-dir with that directory.",
    ),
    command_box(
      "Revoke it",
      operator_commands.revoke(standing.name),
      standing.name,
    ),
    line(
      "Revoke refuses while the member owns sessions or has sessions placed on it, and says which; replace REASON with why.",
    ),
  ])
}

fn seat_words(seat: machines.Seat) -> String {
  case seat {
    machines.Voter -> "voter"
    machines.Learner -> "learner"
    machines.NoSeat -> "none"
  }
}

fn reported(
  seq: Option(Int),
  head: Option(String),
  age: Option(Int),
) -> String {
  case seq {
    None -> "not reported to this daemon"
    Some(number) ->
      "entry "
      <> int.to_string(number)
      <> option.unwrap(head, "")
      <> case age {
        Some(ms) -> ", " <> machines.age_words(ms)
        None -> ""
      }
  }
}

// A node that is configured here and is no active member: the enroll command,
// linked to this orchestrator, with the role the daemon found it to have.
fn not_listed(page: Page(message)) -> Element(message) {
  let machine = page.machine
  let role = case list.contains(machine.roles, machines.Executor) {
    True -> Ok(machines.Executor)
    False ->
      case list.contains(machine.roles, machines.Orchestrator) {
        True -> Ok(machines.Orchestrator)
        False -> Error(Nil)
      }
  }
  html.div([], [
    line(
      "This node is configured here and is not an active member of the membership ledger. Enrolling it signs an entry and writes its bundle.",
    ),
    case role, page.snapshot.ledger {
      Ok(role), Some(machines.Ledger(self_name:, ..)) ->
        command_box(
          "Enroll it",
          operator_commands.enroll(machine.name, machine.node, role, self_name),
          machine.name,
        )
      _, _ ->
        line("The daemon did not state the names an enroll command needs.")
    },
  ])
}

// Each scope that blocks a reopen, with the command that releases it, run on the
// executor with its daemon stopped.
fn release_lines(page: Page(message)) -> Element(message) {
  case long(page) {
    Some(machines.Detail(unclean: [_, ..] as scopes, ..)) ->
      html.div([], [
        html.h4([attribute.class("admin-subheading")], [
          html.text("Release a stuck scope"),
        ]),
        line(
          "Run on this machine with its executor daemon stopped, after checking that nothing from the session still runs.",
        ),
        ..list.map(scopes, fn(scope) {
          command_box(
            "Session " <> scope.session,
            operator_commands.release(scope.session),
            scope.session,
          )
        })
      ])
    Some(_) | None -> element.none()
  }
}

// A label and the box that copies the command, or the words that say why there
// is no box.
fn command_box(
  label: String,
  command: Result(String, Nil),
  name: String,
) -> Element(message) {
  html.div([attribute.class("admin-command")], [
    html.p([attribute.class("admin-sub")], [html.text(label)]),
    case command {
      Ok(text) ->
        element.element(
          "loom-copy",
          [
            attribute.attribute("subject", "operate"),
            attribute.attribute("text", text),
          ],
          [],
        )
      Error(Nil) ->
        line(
          "The name "
          <> name
          <> " cannot be written into a command safely. Run the command by hand.",
        )
    },
  ])
}

// --- activity -------------------------------------------------------------------

fn activity(page: Page(message)) -> Element(message) {
  let machine = page.machine
  case findings(machine) {
    None ->
      line(
        "This daemon does not connect to this machine, so it has no activity to show.",
      )
    Some(found) ->
      html.div([], [
        scopes(found),
        capacity(found),
        stuck(page),
        moves(page),
        case long(page) {
          Some(machines.Detail(more: [_, ..] as cut, ..)) ->
            line(
              "The daemon cut "
              <> string.join(cut, ", ")
              <> " to fit one frame.",
            )
          Some(_) | None -> element.none()
        },
      ])
  }
}

fn scopes(found: Findings) -> Element(message) {
  case found.executor {
    None -> element.none()
    Some(machines.ExecutorFacts(scopes:, scope_limit:, ..)) ->
      html.dl(
        [attribute.class("admin-facts")],
        list.flatten([
          fact("Open scopes", words(int.to_string(scopes.open))),
          fact("Closing", words(int.to_string(scopes.closing))),
          fact("Closed cleanly", words(int.to_string(scopes.closed_clean))),
          fact(
            "Closed, cleanup unknown",
            words(int.to_string(scopes.closed_unknown)),
          ),
          fact("Limit of unclean scopes", words(int.to_string(scope_limit))),
        ]),
      )
  }
}

fn capacity(found: Findings) -> Element(message) {
  case found.orchestrator {
    None -> element.none()
    Some(facts) ->
      html.dl(
        [attribute.class("admin-facts")],
        list.flatten([
          fact(
            "Runtimes reserved",
            words(
              int.to_string(facts.occupied)
              <> " of "
              <> int.to_string(facts.capacity),
            ),
          ),
          fact("Resident sessions", words(int.to_string(facts.resident))),
          fact("Moves in flight", words(int.to_string(facts.moves_in_flight))),
          case facts.imports {
            Some(machines.Receiving) -> fact("Accepts moves", words("yes"))
            Some(machines.NotReceiving) -> fact("Accepts moves", words("no"))
            None -> []
          },
        ]),
      )
  }
}

fn stuck(page: Page(message)) -> Element(message) {
  case long(page) {
    Some(machines.Detail(unclean: [_, ..] as scopes, ..)) ->
      html.div([], [
        html.h4([attribute.class("admin-subheading")], [
          html.text("Scopes that block a reopen"),
        ]),
        html.ul(
          [attribute.class("admin-reasons")],
          list.map(scopes, fn(scope) {
            html.li([attribute.class("admin-sub")], [
              html.text(scope.session <> " · " <> stuck_words(scope)),
            ])
          }),
        ),
      ])
    Some(_) | None -> element.none()
  }
}

fn stuck_words(scope: Unclean) -> String {
  case scope.stuck {
    machines.Closing -> "closing, its close never finished"
    machines.UnknownCleanup(count: Some(count)) ->
      "closed with " <> int.to_string(count) <> " children not proven gone"
    machines.UnknownCleanup(count: None) ->
      "closed without proof that every child is gone"
  }
}

// The moves in flight. An orchestrator other than the asking daemon states them
// in its own long list; the asking daemon's are in the overview.
fn moves(page: Page(message)) -> Element(message) {
  let listed = case page.machine.whose, long(page) {
    machines.This, _ -> page.snapshot.moves
    machines.Other, Some(machines.Detail(moves:, ..)) -> moves
    machines.Other, None -> []
  }
  case listed {
    [] -> element.none()
    _ ->
      html.div([], [
        html.h4([attribute.class("admin-subheading")], [html.text("Moves")]),
        html.ul(
          [attribute.class("admin-reasons")],
          list.map(listed, fn(move) {
            html.li([attribute.class("admin-sub")], [
              html.text(move_words(move)),
            ])
          }),
        ),
      ])
  }
}

fn move_words(move: machines.Move) -> String {
  move.session
  <> " to "
  <> move.to
  <> " · "
  <> case move.phase {
    machines.Running -> "running"
    machines.Waiting -> "waiting"
  }
  <> case move.stalled_ms {
    Some(ms) -> " · stalled " <> machines.uptime_words(ms)
    None -> ""
  }
  <> case move.reason {
    Some(reason) -> " · " <> reason
    None -> ""
  }
}
