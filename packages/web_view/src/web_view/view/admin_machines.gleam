//// The admin page's Deployment section: what the owner's machines are, grouped
//// by what they do, and how each is (protocol-change/085, the addenda of
//// 2026-10-16 and 2026-10-19).
////
//// The section follows People and Sessions. Under its heading is one line
//// (`machines.summary_words`): how many machines there are, how many of each
//// kind, whether all are ok, and the first reason one is not. Under it are, when
//// they apply, a line saying this daemon's copy of the session directory is
//// unconfirmed and a line naming what the daemon left out of the reply to fit one
//// frame. Then the machines.
////
//// ## Grouped by what a machine does
////
//// The machines are listed in three groups, each under a small heading:
//// Orchestrators (this daemon first, marked "this daemon"), Executors, and
//// directory members that are neither (`machines.group_of`). The pools the daemon
//// configures follow as a fourth group, each with the executors it admits and
//// how many of them could take a session now. A group with nothing in it is not
//// drawn.
////
//// A row shows what matters for its group and nothing else. An orchestrator
//// shows its build, its resident sessions and slots, how long it has been up and
//// its last report; an executor shows its platform, enforcement, toolchains,
//// open scopes and last report. A fact the machine did not state is left out
//// rather than drawn as a dash, so a row never becomes a wall of dashes. The
//// ledger's standing is shown only on a daemon that runs from a ledger.
////
//// ## A daemon on its own
////
//// A daemon with no `[distribution]` table (`machines.Standalone`) connects to no
//// other machine, and its node name is one the BEAM made up. The section then
//// draws one card titled by the machine's host name and labelled "This
//// machine" ("This machine" alone when the daemon could not read its host
//// name), with its build and sessions, and a quiet note that distribution is
//// not configured and where the setup is described. The made-up node name is
//// never drawn (`machines.title`).
////
//// ## A row is a button
////
//// A machine's row is a button that sends the message naming the machine the
//// server drew into the tree. The page then reads that machine and draws its page
//// under the section (`view/admin_machine`). The button is a click beneath the
//// admin body, which the admin socket already admits, so the section adds no
//// event class, scope or route. A pool is not a machine and its row is not a
//// button.
////
//// ## A machine this daemon does not dial
////
//// A member of the ledger that this daemon's configuration does not hold is
//// listed in its group, quieter than the rest, with "not linked from here" where
//// the state pill would be. The daemon never dials it, so the row has no facts
//// of a report, and its standing in the ledger is stated.
////
//// ## One tree for every width
////
//// The markup is the same at every width and the stylesheet lays it out. On a
//// wide screen a row is the name on the left and its facts in a wrapping line
//// on the right; on a phone the facts stack under the name as label and value.
//// Nothing in a row is a table cell, so no column can starve another: the pills
//// and labels never wrap, and a long name breaks only where it would overflow.
////
//// ## What is drawn as what
////
//// Every name, key, node, platform, enforcement and toolchain is another daemon's
//// or the operator's text, drawn as a text node. The classes are complete fixed
//// literals, and the only ones chosen by the data are the pill tints
//// `machines.pill_class` returns for a closed type and the fixed `unlinked`
//// modifier of a row the daemon does not dial. A row is keyed by its place in its
//// group, so no name becomes a key.
////
//// ## Flow
////
//// `view` → `drawn` → `standalone` or `group` → `row` → `facts` → `pools`
////
//// 1. `view` draws the section from what the page holds of the deployment: the
////    machines, or the words for a deployment not yet read or one that could not
////    be.
//// 2. `drawn` draws the heading, the summary and the notes, then `standalone`
////    for a daemon on its own or a `group` for each kind of machine, then `pools`.
//// 3. `row` draws one machine as its button, with `facts` choosing the facts its
////    group shows. The chosen machine's page is drawn by `view/admin_machine`
////    beneath the section.

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
  type Group, type Held, type Ledgered, type Machine, type Pool, type Snapshot,
  Dialled, Enrolled, ExecutorGroup, Failed, Findings, Known, MemberGroup,
  NotLinkedFromHere, NotListed, NothingYet, OrchestratorGroup, Standalone, This,
  Unconfirmed, Unledgered,
}
import web_view/sessions.{type Entry}

/// What the section is given.
pub type Section(message) {
  Section(
    /// What the page holds of the deployment.
    held: Held,
    /// The node of the chosen machine, if one is.
    chosen: Option(String),
    /// The message a row sends, given the node the row was drawn for.
    choose: fn(String) -> message,
    /// The chosen machine's page, drawn under the section, or nothing.
    page: Element(message),
    /// The owner's sessions in this daemon's catalogue, which say how many
    /// sessions this daemon holds when its own report does not.
    entries: List(Entry),
  )
}

/// The section.
///
/// ## Examples
///
/// ```gleam
/// // admin_machines.view(Section(machines.NothingYet, None, choose, element.none(), []))
/// ```
pub fn view(section: Section(message)) -> Element(message) {
  html.section(
    [attribute.class("admin-section"), attribute.aria_label("Deployment")],
    case section.held {
      NothingYet -> [
        heading(),
        html.p([attribute.class("home-empty")], [
          html.text("Reading the deployment."),
        ]),
      ]
      Failed(kept: None) -> [
        heading(),
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

fn heading() -> Element(message) {
  html.h2([attribute.class("home-heading")], [html.text("Deployment")])
}

/// The heading, the summary, its notes, the machines and the chosen machine's
/// page. A standalone daemon that lists only itself is one card; anything else is
/// the groups, so a ledger member listed beside a standalone daemon is still seen.
fn drawn(
  snapshot: Snapshot,
  section: Section(message),
) -> List(Element(message)) {
  // Render standalone card or grouped deployment machines list.
  let body = case snapshot.distribution, snapshot.machines {
    Standalone, [only] if only.whose == This -> [
      standalone(snapshot, only, section),
    ]
    _, [] -> [
      html.p([attribute.class("home-empty")], [
        html.text("This daemon has no other machine configured."),
      ]),
    ]
    _, _ ->
      list.flatten([
        group(snapshot, OrchestratorGroup, section),
        group(snapshot, ExecutorGroup, section),
        group(snapshot, MemberGroup, section),
        pools(snapshot.pools),
      ])
  }

  list.flatten([
    [
      heading(),
      html.p([attribute.class("admin-summary")], [
        html.text(machines.summary_words(snapshot.machines)),
      ]),
      notes(snapshot),
    ],
    body,
    [section.page],
  ])
}

/// The lines under the summary: the directory copy when it is unconfirmed and
/// what the daemon left out of the reply.
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

/// A daemon on its own: one card for this machine and the note that says why
/// there is nothing else to list.
fn standalone(
  snapshot: Snapshot,
  machine: Machine,
  section: Section(message),
) -> Element(message) {
  html.div([attribute.class("admin-group")], [
    html.ul([attribute.class("admin-fleet")], [
      row(snapshot, machine, section),
    ]),
    html.p([attribute.class("admin-note")], [
      html.text(
        "Distribution is not configured, so this daemon uses no other machine. Setting up a distributed Loom (docs/distributed-setup.md) says how to add executors and orchestrators.",
      ),
    ]),
  ])
}

/// The machines of one group under its heading, or nothing for a group with none.
fn group(
  snapshot: Snapshot,
  group: Group,
  section: Section(message),
) -> List(Element(message)) {
  let members =
    list.filter(snapshot.machines, fn(machine) {
      machines.group_of(machine) == group
    })

  // Render group heading and fleet list if non-empty.
  case members {
    [] -> []
    [_, ..] -> [
      html.div([attribute.class("admin-group")], [
        html.h3([attribute.class("admin-subheading")], [
          html.text(group_words(group)),
          html.span([attribute.class("home-count")], [
            html.text(int.to_string(list.length(members))),
          ]),
        ]),
        keyed.ul(
          [attribute.class("admin-fleet")],
          list.index_map(members, fn(machine, index) {
            #(int.to_string(index), row(snapshot, machine, section))
          }),
        ),
      ]),
    ]
  }
}

/// Returns the display title for a machine group category.
fn group_words(group: Group) -> String {
  case group {
    OrchestratorGroup -> "Orchestrators"
    ExecutorGroup -> "Executors"
    MemberGroup -> "Directory members"
  }
}

/// One machine, as the button that opens its page: its name and state, the node
/// and anything else that names it, then the facts its group shows.
fn row(
  snapshot: Snapshot,
  machine: Machine,
  section: Section(message),
) -> Element(message) {
  let title = machines.title(snapshot, machine)

  // Check if this machine is currently selected in view.
  let current = case section.chosen {
    Some(node) if node == machine.node -> [attribute.aria_current("true")]
    Some(_) | None -> []
  }

  // Dim unlinked fleet machines.
  let quiet = case machine.here {
    Dialled(..) -> []
    NotLinkedFromHere -> [attribute.class("unlinked")]
  }

  html.li([attribute.class("admin-node"), ..quiet], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("admin-pick"),
        attribute.class("admin-node-pick"),
        event.on_click(section.choose(machine.node)),
        ..current
      ],
      [
        html.span([attribute.class("admin-node-head")], [
          html.span([attribute.class("admin-name")], [html.text(title.name)]),
          state(machine),
        ]),
        subline(machine, title),
        facts(snapshot, machine, section.entries),
      ],
    ),
  ])
}

/// The quiet line under the name: what the name is when the title says ("This
/// machine" under a host name), the node string when it says something the name
/// does not, "this daemon" for the asking daemon, and the roles beyond the one
/// its group already says.
fn subline(machine: Machine, title: machines.Title) -> Element(message) {
  let parts =
    list.flatten([
      case title.label {
        Some(words) -> [html.span([], [html.text(words)])]
        None -> []
      },
      case title.node {
        Some(node) -> [
          html.span([attribute.class("admin-node-id")], [html.text(node)]),
        ]
        None -> []
      },
      case machine.whose {
        This -> [html.span([], [html.text("this daemon")])]
        machines.Other -> []
      },
      case extra_roles(machine) {
        [] -> []
        roles -> [html.span([], [html.text(string.join(roles, ", "))])]
      },
    ])

  // Render subline span if any detail parts are present.
  case parts {
    [] -> element.none()
    _ -> html.span([attribute.class("admin-node-sub")], parts)
  }
}

/// The roles a machine has beyond the one its group is named for: an
/// orchestrator that is also a directory member says so.
fn extra_roles(machine: Machine) -> List(String) {
  // Determine primary group role to filter out.
  let named = case machines.group_of(machine) {
    OrchestratorGroup -> machines.Orchestrator
    ExecutorGroup -> machines.Executor
    MemberGroup -> machines.Member
  }

  machine.roles
  |> list.filter(fn(role) { role != named })
  |> list.map(machines.role_words)
}

/// The state pill, or the words for a machine the daemon does not dial.
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

/// The facts the machine's group shows, each a label and a value, leaving out the
/// ones the machine did not state. An orchestrator says how it runs and what it
/// holds; an executor says what its machine provides and how full it is. Both say
/// when they last reported and, on a daemon with a ledger, their standing in it.
fn facts(
  snapshot: Snapshot,
  machine: Machine,
  entries: List(Entry),
) -> Element(message) {
  // Extract findings if machine is dialled.
  let found = case machine.here {
    Dialled(findings:) -> Some(findings)
    NotLinkedFromHere -> None
  }

  // Extract optional orchestrator and executor fact findings.
  let orchestrator = option.then(found, fn(each) { each.orchestrator })
  let executor = option.then(found, fn(each) { each.executor })

  // Compile group-specific metrics and attributes.
  let own = case machines.group_of(machine) {
    OrchestratorGroup -> [
      #("Build", option.then(found, machines.build_words)),
      #("Sessions", case orchestrator, machine.whose {
        Some(each), _ -> Some(int.to_string(each.resident) <> " resident")
        None, This -> Some(held_here(entries))
        None, machines.Other -> None
      }),
      #(
        "Slots",
        option.map(orchestrator, fn(each) {
          int.to_string(each.occupied) <> " of " <> int.to_string(each.capacity)
        }),
      ),
      #(
        "Up for",
        option.then(found, fn(each) { each.uptime_ms })
          |> option.map(machines.uptime_words),
      ),
    ]
    ExecutorGroup -> [
      #("Platform", option.then(executor, fn(each) { each.platform })),
      #("Enforcement", option.then(executor, fn(each) { each.enforcement })),
      #("Toolchains", case executor {
        Some(machines.ExecutorFacts(toolchains: [_, ..] as listed, ..)) ->
          Some(string.join(listed, ", "))
        Some(_) | None -> None
      }),
      #(
        "Scopes",
        option.map(executor, fn(each) {
          int.to_string(each.scopes.open)
          <> " open of "
          <> int.to_string(each.scope_limit)
        }),
      ),
    ]
    MemberGroup -> [#("Build", option.then(found, machines.build_words))]
  }

  let stated =
    list.filter_map(
      list.append(own, [
        #("Last report", last_report(machine.ledgered)),
        #("Ledger", standing_of(snapshot, machine.ledgered)),
      ]),
      fn(pair) {
        case pair.1 {
          Some(value) -> Ok(fact(pair.0, value))
          None -> Error(Nil)
        }
      },
    )

  // Return fact elements or none if empty.
  case stated {
    [] -> element.none()
    _ -> html.span([attribute.class("admin-node-facts")], stated)
  }
}

/// How many sessions this daemon's catalogue holds and how many of them run, for
/// the asking daemon when its report carries no orchestrator facts, as a daemon
/// without distribution's does.
fn held_here(entries: List(Entry)) -> String {
  let running =
    list.count(entries, fn(entry) {
      case entry.residency {
        sessions.Live -> True
        sessions.Saved
        | sessions.Blocked
        | sessions.FailedStart(..)
        | sessions.Moving(..) -> False
      }
    })
  int.to_string(list.length(entries))
  <> " · "
  <> int.to_string(running)
  <> " running"
}

// One fact: its label and its value, both text.
fn fact(label: String, value: String) -> Element(message) {
  html.span([attribute.class("admin-node-fact")], [
    html.span([attribute.class("admin-node-label")], [html.text(label)]),
    html.span([attribute.class("admin-node-value")], [html.text(value)]),
  ])
}

// The ledger's standing, only on a daemon that runs from a ledger: a daemon
// without one has nothing to say about it on every row.
fn standing_of(snapshot: Snapshot, ledgered: Ledgered) -> Option(String) {
  case snapshot.ledger, ledgered {
    _, Unledgered | None, _ -> None
    Some(_), Enrolled(..) | Some(_), NotListed -> Some(standing(ledgered))
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

/// How long ago the member reported its head to this daemon, or nothing when it
/// has not or the machine is not in the ledger.
fn last_report(ledgered: Ledgered) -> Option(String) {
  case ledgered {
    Enrolled(standing: machines.Standing(age_ms: Some(age), ..)) ->
      Some(machines.age_words(age))
    Enrolled(..) -> Some("not reported")
    NotListed | Unledgered -> None
  }
}

/// The pools under their heading: each pool's name, how many of its executors
/// could take a session now, and which executors it admits.
fn pools(listed: List(Pool)) -> List(Element(message)) {
  case listed {
    [] -> []
    [_, ..] -> [
      html.div([attribute.class("admin-group")], [
        html.h3([attribute.class("admin-subheading")], [
          html.text("Pools"),
          html.span([attribute.class("home-count")], [
            html.text(int.to_string(list.length(listed))),
          ]),
        ]),
        keyed.ul(
          [attribute.class("admin-fleet")],
          list.index_map(listed, fn(pool, index) {
            #(int.to_string(index), pool_row(pool))
          }),
        ),
      ]),
    ]
  }
}

/// One pool. Its pill is ok when every executor could take a session, waiting
/// when some could, and down when none could.
fn pool_row(pool: Pool) -> Element(message) {
  let ready = list.length(pool.eligible)
  let all = list.length(pool.executors)

  // Select pill tint according to ready executor ratio.
  let tint = case ready {
    0 -> machines.pill_class(machines.Down)
    _ if ready == all -> machines.pill_class(machines.Healthy)
    _ -> machines.pill_class(machines.Degraded)
  }

  html.li([attribute.class("admin-node")], [
    html.div([attribute.class("admin-node-pick")], [
      html.span([attribute.class("admin-node-head")], [
        html.span([attribute.class("admin-name")], [html.text(pool.name)]),
        html.span([attribute.class("pill"), attribute.class(tint)], [
          html.text(
            int.to_string(ready) <> " of " <> int.to_string(all) <> " ready",
          ),
        ]),
      ]),
      html.span([attribute.class("admin-node-facts")], [
        fact("Executors", case pool.executors {
          [] -> "none"
          names -> string.join(names, ", ")
        }),
      ]),
    ]),
  ])
}
