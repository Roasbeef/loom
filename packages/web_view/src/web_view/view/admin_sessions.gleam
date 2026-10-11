//// The admin page's session section: the owner's sessions to choose from, the
//// chosen session's members with the changes the owner makes to each, and the
//// form that invites someone new into it.
////
//// A session is chosen by pressing its row, which sends the message naming the
//// session the server drew into the tree. The page then reads that session's
//// members (`sessions.members`) and draws them under the list: each member's
//// name, identity and role, a button that raises an observer to operator or
//// lowers an operator to observer, and a two-step button that removes the
//// member from the session (`view/admin_buttons`). Raising a role is a grant
//// and counts against the credential's allowance; lowering one and removing a
//// member only reduce access and cost nothing.
////
//// A session that is private, one that shares its notes and history with its
//// workspace, cannot be shared, and the registry refuses an invitation into it
//// (`NotIsolated`). The read of its members reports the scope it was created
//// with (`grants.Selection.scope`), so the page draws no form for it and says
//// why in one sentence, rather than drawing a form that can only be refused.
////
//// The invitation form has two fields and no others: a name, which is the
//// owner's suggestion and which the invitee may replace when they claim, and a
//// role, observer or operator. `fields` is the one place that says what a
//// submitted form may hold, and it refuses any other field, a repeated one and
//// a role that is not one of the two words, so the daemon never sees a role the
//// page did not offer. The session is not a field: it is the session the form
//// was drawn under, carried by the message the server drew.
////
//// A session's row says who holds it and whether it may be shared, after its
//// path (`grants.summary_words`), from the summaries the read made for every
//// listed session, so the list answers before anything is pressed. A session the
//// registry did not answer for has no line.
////
//// The invitation form is keyed by how many invitations the page has made, so
//// the invitation that was just made opens a fresh form: the name field is empty
//// and the role is back to observer. A read, a refusal or a change to a member
//// leaves the form, and whatever is typed in it, as it was.
////
//// The section ends with a slot for the claim an invitation made, under the form
//// that made it (`view/admin_claim`). A notice about a change (`view/notice`) is
//// drawn under the members' heading, or beside the form for an invitation. Each
//// is one child of its parent whether or not it is drawn, so no other child's
//// path moves.
////
//// Every name is a peer's and a session's name is the owner's; each is a text
//// node, in a label's words as well. A session's identity is the catalogue's and
//// is carried by a message, never an attribute. The classes are complete
//// literals.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/creations.{Private, Shareable}
import web_view/grants.{type Claim, type Holder, type Selection, type Summary}
import web_view/invites.{type Role}
import web_view/sessions.{type Entry}
import web_view/view/admin_buttons.{type Busy, type Presses}
import web_view/view/admin_claim
import web_view/view/admin_people
import web_view/view/heading
import web_view/view/notice.{type Spoken}

/// The section: the sessions to choose from and, below them, the chosen
/// session's members and its invitation form. `chosen` is the session the owner
/// pressed and `selection` is what the last read found for it, which is
/// nothing when the catalogue holds no such session any longer.
///
/// `spoken` is the last thing the page said about an ask and `claim` the claim on
/// screen, if one is; each is drawn only where it belongs.
///
/// `summaries` says each session's people and scope under its path, and `invited`
/// is how many invitations the page has made, which keys the invitation form so
/// each one opens it empty.
///
/// `armed` is the change the owner has pressed once and `waiting` the one the
/// daemon is making, which is how a private session's control tells a question
/// from a task that is running.
///
/// ## Examples
///
/// ```gleam
/// // admin_sessions.view(entries, Some(id), selection, [], None, None, None, None, 0, presses, admin_buttons.Free)
/// ```
pub fn view(
  entries: List(Entry),
  chosen: Option(String),
  selection: Option(Selection),
  summaries: List(Summary),
  armed: Option(grants.Action),
  waiting: Option(grants.Action),
  spoken: Option(Spoken),
  claim: Option(Claim),
  invited: Int,
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.section(
    [attribute.class("admin-section"), attribute.aria_label("Sessions")],
    [
      html.h2([attribute.class("home-heading")], [html.text("Sessions")]),
      case entries {
        [] ->
          html.p([attribute.class("home-empty")], [
            html.text("The owner holds no sessions yet."),
          ])
        [_, ..] ->
          html.ul(
            [attribute.class("admin-list")],
            list.map(entries, fn(entry) {
              pick(entry, chosen, summaries, presses)
            }),
          )
      },
      members(
        entries,
        chosen,
        selection,
        armed,
        waiting,
        spoken,
        invited,
        presses,
        busy,
      ),
      admin_claim.for_session(claim, invited, presses.dismiss),
    ],
  )
}

// One session's row, a button that chooses it. The chosen row says so with
// `aria-current`, which the stylesheet tints.
fn pick(
  entry: Entry,
  chosen: Option(String),
  summaries: List(Summary),
  presses: Presses(message),
) -> Element(message) {
  let current = case chosen {
    Some(id) if id == entry.id -> [attribute.aria_current("true")]
    Some(_) | None -> []
  }
  html.li([attribute.class("admin-row")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("admin-pick"),
        event.on_click(presses.choose(entry.id)),
        ..current
      ],
      [
        html.span([attribute.class("admin-name")], [
          html.text(sessions.label(entry)),
        ]),
        html.span([attribute.class("admin-sub")], [
          html.text(
            heading.shorten_path(entry.workspace) <> summary(entry, summaries),
          ),
        ]),
      ],
    ),
  ])
}

// The words after a session's path: its people and scope when the registry
// answered for it, and nothing when it did not.
fn summary(entry: Entry, summaries: List(Summary)) -> String {
  case list.find(summaries, fn(held) { held.session == entry.id }) {
    Ok(held) -> " · " <> grants.summary_words(held)
    Error(Nil) -> ""
  }
}

// The chosen session's members and its invitation form, or the line that says
// to choose one, or that the one chosen is gone.
fn members(
  entries: List(Entry),
  chosen: Option(String),
  selection: Option(Selection),
  armed: Option(grants.Action),
  waiting: Option(grants.Action),
  spoken: Option(Spoken),
  invited: Int,
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  case chosen, selection {
    None, _ ->
      html.p([attribute.class("home-empty")], [
        html.text("Choose a session to see who holds it and to invite someone."),
      ])
    Some(_), None ->
      html.p([attribute.class("home-empty")], [
        html.text("That session is no longer in the catalogue."),
      ])
    Some(_), Some(selection) -> {
      let label = named(entries, selection.session)
      html.div([attribute.class("admin-members")], [
        html.h3([attribute.class("admin-subheading")], [
          html.text("Members of " <> label),
        ]),
        notice.at_members(spoken),
        holders(selection, label, armed, presses, busy),
        truncation(selection.more),
        sharing(
          selection,
          label,
          residency_of(entries, selection.session),
          armed,
          waiting,
          spoken,
          invited,
          presses,
          busy,
        ),
      ])
    }
  }
}

// The invitation form and the notice beside it for a session that may be shared,
// and the sentence that says why there is none for one that may not. Both are
// one child of the members' block, so the claim's slot after it never moves.
fn sharing(
  selection: Selection,
  label: String,
  residency: Option(sessions.Residency),
  armed: Option(grants.Action),
  waiting: Option(grants.Action),
  spoken: Option(Spoken),
  invited: Int,
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  case selection.scope {
    Shareable ->
      keyed.div([attribute.class("admin-invitation")], [
        #(
          "invite-" <> int.to_string(invited),
          invitation(selection.session, label, presses, busy),
        ),
        #("notice", html.div([], [notice.at_invitation(spoken)])),
      ])
    Private ->
      html.div([attribute.class("admin-private")], [
        html.p([attribute.class("admin-lead")], [html.text(private_words)]),
        make_shareable(
          selection.session,
          residency,
          armed,
          waiting,
          presses,
          busy,
        ),
        notice.at_invitation(spoken),
      ])
  }
}

/// The sentence a private session's control opens with. The session page says
/// the same words (`view/share.private_words`).
pub const private_words =
  "Private session: it shares the workspace's notes and history, so it cannot be shared. Sessions created with Shareable can be."

// What a private session offers. The owner's page makes a session shareable in
// one task, so the control is a button that asks first; while the task runs the
// button is the sentence that says so. A session nothing runs is isolated and
// stays saved, which the question says, and a session the daemon will not open
// from a page, whose creation was never reconciled or whose recovery stopped
// it, is offered nothing, since the task would refuse it.
fn make_shareable(
  session: String,
  residency: Option(sessions.Residency),
  armed: Option(grants.Action),
  waiting: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  let action = grants.MakeShareable(session)
  case waiting, residency {
    Some(held), _ if held == action ->
      html.p([attribute.class("admin-lead"), attribute.role("status")], [
        html.text(
          "Making this session shareable: stopping it, moving it to its own history and resuming it. This can take a minute.",
        ),
      ])
    _, Some(sessions.Live) ->
      admin_buttons.asking(
        "Make shareable",
        "Make this session shareable? It will stop, move to its own history, and resume. People you invite will be able to read what it already holds.",
        "Make shareable",
        action,
        armed,
        presses,
        busy,
      )
    _, Some(sessions.Saved) ->
      admin_buttons.asking(
        "Make shareable",
        "Make this session shareable? It will move to its own history and stay saved. People you invite will be able to read what it already holds.",
        "Make shareable",
        action,
        armed,
        presses,
        busy,
      )
    _, Some(sessions.Blocked) | _, None -> element.none()
  }
}

// Whether the session the members block is about runs, from the list the page
// holds, or nothing for a session the list no longer holds.
fn residency_of(
  entries: List(Entry),
  session: String,
) -> Option(sessions.Residency) {
  case list.find(entries, fn(entry) { entry.id == session }) {
    Ok(entry) -> Some(entry.residency)
    Error(Nil) -> None
  }
}

// The session's name for the page's words: the entry's label, or the identity's
// first characters for a session the list no longer holds.
fn named(entries: List(Entry), session: String) -> String {
  case list.find(entries, fn(entry) { entry.id == session }) {
    Ok(entry) -> sessions.label(entry)
    Error(Nil) ->
      sessions.label(sessions.Entry(
        session,
        "",
        "",
        0,
        sessions.Saved,
        None,
        None,
        None,
        None,
      ))
  }
}

// The members' list, or the line that says there are none.
fn holders(
  selection: Selection,
  label: String,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  case selection.holders {
    [] ->
      html.p([attribute.class("home-empty")], [
        html.text("Nobody but the owner holds this session."),
      ])
    rows ->
      html.ul(
        [attribute.class("admin-list")],
        list.map(rows, fn(row) {
          holder(selection.session, label, row, armed, presses, busy)
        }),
      )
  }
}

// One member: name, identity and role, and the buttons that change its role in
// this session or remove it from it.
fn holder(
  session: String,
  label: String,
  row: Holder,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.li([attribute.class("admin-row")], [
    html.div([attribute.class("admin-text")], [
      html.span([attribute.class("admin-name")], [
        html.text(row.name),
        admin_people.identity(row.principal),
      ]),
      html.span([attribute.class("admin-sub")], [
        html.text(invites.role_word(row.role)),
      ]),
    ]),
    html.div([attribute.class("admin-actions")], [
      role_button(session, row, presses, busy),
      admin_buttons.guarded(
        "Remove",
        "Remove " <> row.name <> " from " <> label,
        grants.RevokeMembership(session, row.principal),
        armed,
        presses,
        busy,
      ),
    ]),
  ])
}

// The button that moves a member to the other role.
fn role_button(
  session: String,
  row: Holder,
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  case row.role {
    invites.Observer ->
      admin_buttons.granting(
        "Make operator",
        "admin-act",
        presses.ask(grants.SetRole(session, row.principal, invites.Operator)),
        busy,
      )
    invites.Operator ->
      admin_buttons.plain(
        "Make observer",
        "admin-act",
        presses.ask(grants.SetRole(session, row.principal, invites.Observer)),
        busy,
      )
  }
}

// The line that says the page lists the first members only, or nothing.
fn truncation(more: grants.More) -> Element(message) {
  case more {
    grants.Whole -> element.none()
    grants.Truncated ->
      html.p([attribute.class("home-empty")], [
        html.text(
          "More members exist than this page lists. Run loom access members to page through them.",
        ),
      ])
  }
}

// The form that invites someone into the chosen session. The two fields are
// uncontrolled, the one submit sends both, and the handler is the component's,
// built for this session. While a request is out the fields and the button are
// disabled.
fn invitation(
  session: String,
  label: String,
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  let locked = case busy {
    admin_buttons.Free | admin_buttons.Spent(_) -> []
    admin_buttons.Occupied -> [attribute.disabled(True)]
  }
  let granting = case busy {
    admin_buttons.Spent(words:) -> [attribute.title(words)]
    admin_buttons.Free | admin_buttons.Occupied -> []
  }
  html.form(
    [
      attribute.class("admin-invite"),
      attribute.aria_label("Invite to this session"),
      presses.invite(session),
    ],
    [
      html.p([attribute.class("admin-lead")], [
        html.text(
          "Invite someone to "
          <> label
          <> ". This makes a single-use claim token that expires in 60 minutes.",
        ),
      ]),
      html.div([attribute.class("admin-fields")], [
        html.input([
          attribute.type_("text"),
          attribute.name("name"),
          attribute.aria_label("Name"),
          attribute.placeholder("Name (optional)"),
          attribute.attribute("maxlength", "256"),
          attribute.autocomplete("off"),
          ..locked
        ]),
        html.select(
          [attribute.name("role"), attribute.aria_label("Role"), ..locked],
          [
            html.option([attribute.value("observer")], "Observer: can follow"),
            html.option(
              [attribute.value("operator")],
              "Operator: can send and approve",
            ),
          ],
        ),
        html.button(
          [
            attribute.type_("submit"),
            attribute.class("admin-act"),
            ..list.append(granting, locked)
          ],
          [html.text("Create invitation")],
        ),
      ]),
    ],
  )
}

/// The name and role a submitted invitation form stands for, or a refusal:
/// exactly one `name`, exactly one `role` that is `observer` or `operator`, and
/// no other field. A refused event is dropped by Lustre with no message, so the
/// daemon never sees a role the form did not offer.
///
/// ## Examples
///
/// ```gleam
/// assert admin_sessions.fields([#("name", "Ana"), #("role", "operator")])
///   == Ok(#("Ana", invites.Operator))
/// assert admin_sessions.fields([#("role", "owner"), #("name", "")]) == Error(Nil)
/// ```
pub fn fields(listed: List(#(String, String))) -> Result(#(String, Role), Nil) {
  let names = list.filter(listed, fn(field) { field.0 == "name" })
  let roles = list.filter(listed, fn(field) { field.0 == "role" })
  case names, roles, list.length(listed) {
    [#(_, name)], [#(_, "observer")], 2 -> Ok(#(name, invites.Observer))
    [#(_, name)], [#(_, "operator")], 2 -> Ok(#(name, invites.Operator))
    _, _, _ -> Error(Nil)
  }
}

/// The form fields the browser lists in a submit event's detail, in order. The
/// component's handler decodes them with this and judges them with `fields`.
///
/// ## Examples
///
/// ```gleam
/// // event.on("submit", decode.subfield(["detail", "formData"], admin_sessions.form_data(), ...))
/// ```
pub fn form_data() -> decode.Decoder(List(#(String, String))) {
  decode.list({
    use name <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(#(name, value))
  })
}
