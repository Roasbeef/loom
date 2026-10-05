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
//// The invitation form has two fields and no others: a name, which is the
//// owner's suggestion and which the invitee may replace when they claim, and a
//// role, observer or operator. `fields` is the one place that says what a
//// submitted form may hold, and it refuses any other field, a repeated one and
//// a role that is not one of the two words, so the daemon never sees a role the
//// page did not offer. The session is not a field: it is the session the form
//// was drawn under, carried by the message the server drew.
////
//// Every name is a peer's and a session's name is the owner's; each is a text
//// node, in a label's words as well. A session's identity is the catalogue's and
//// is carried by a message, never an attribute. The classes are complete
//// literals.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/grants.{type Holder, type Selection}
import web_view/invites.{type Role}
import web_view/sessions.{type Entry}
import web_view/view/admin_buttons.{type Busy, type Presses}
import web_view/view/heading

/// The section: the sessions to choose from and, below them, the chosen
/// session's members and its invitation form. `chosen` is the session the owner
/// pressed and `selection` is what the last read found for it, which is
/// nothing when the catalogue holds no such session any longer.
///
/// ## Examples
///
/// ```gleam
/// // admin_sessions.view(entries, Some(id), selection, None, presses, admin_buttons.Free)
/// ```
pub fn view(
  entries: List(Entry),
  chosen: Option(String),
  selection: Option(Selection),
  armed: Option(grants.Action),
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
            list.map(entries, fn(entry) { pick(entry, chosen, presses) }),
          )
      },
      members(entries, chosen, selection, armed, presses, busy),
    ],
  )
}

// One session's row, a button that chooses it. The chosen row says so with
// `aria-current`, which the stylesheet tints.
fn pick(
  entry: Entry,
  chosen: Option(String),
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
          html.text(heading.shorten_path(entry.workspace)),
        ]),
      ],
    ),
  ])
}

// The chosen session's members and its invitation form, or the line that says
// to choose one, or that the one chosen is gone.
fn members(
  entries: List(Entry),
  chosen: Option(String),
  selection: Option(Selection),
  armed: Option(grants.Action),
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
        holders(selection, label, armed, presses, busy),
        truncation(selection.more),
        invitation(selection.session, label, presses, busy),
      ])
    }
  }
}

// The session's name for the page's words: the entry's label, or the identity's
// first characters for a session the list no longer holds.
fn named(entries: List(Entry), session: String) -> String {
  case list.find(entries, fn(entry) { entry.id == session }) {
    Ok(entry) -> sessions.label(entry)
    Error(Nil) ->
      sessions.label(sessions.Entry(session, "", "", 0, sessions.Saved, None))
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
        html.span([attribute.class("admin-id")], [html.text(row.principal)]),
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
      admin_buttons.plain(
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
    admin_buttons.Free -> []
    admin_buttons.Occupied -> [attribute.disabled(True)]
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
          [attribute.type_("submit"), attribute.class("admin-act"), ..locked],
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
