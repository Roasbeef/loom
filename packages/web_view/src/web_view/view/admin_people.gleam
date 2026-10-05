//// The admin page's two lists of people: every principal the catalogue holds,
//// and, apart, the invitations still waiting to be claimed.
////
//// A principal's row says who it is and what it can authenticate with, in words
//// the owner can act on: `active` with the fingerprint of the credential and
//// when a claim bound it, `invited` with the time the claim has left,
//// `invitation expired`, or `no credential`. A claim is never drawn, because
//// the catalogue holds only its digest, and a credential only as the first
//// sixteen characters of its own, which is enough to compare with what `loom
//// claim` printed (`web_view/grants`).
////
//// Each member's row offers the two changes the owner makes to a person, not
//// to a session: rotating its credential, which voids what it held and makes a
//// new claim, and revoking its credentials, which is a two-step button
//// (`view/admin_buttons`). The owner's row offers nothing, since the owner's
//// access is not the page's to change. The pending list is the same people
//// seen by one fact: those whose claim is open, each with a Void button, so
//// an invitation sent to the wrong person is easy to take back.
////
//// A principal that holds browser logins lists them beneath its row, each with
//// the words the home's own list uses and a two-step "Revoke sign-in" button
//// (protocol-change/065, the eighth pull request); the owner's own login the
//// page was opened from is marked "This browser". A principal with more than
//// the page lists says so and leaves the rest to `loom access signins`.
////
//// Every name is a peer's and is drawn as a text node, in a label's words as
//// well. Every identity is the catalogue's and is a text node too; nothing here
//// is an attribute, a class or a key made from either. The classes are
//// complete literals.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/grants.{type Credential, type Logins, type Principal}
import web_view/sessions
import web_view/signins.{type Signin}
import web_view/view/admin_buttons.{type Busy, type Presses}
import web_view/view/signins as signins_view

/// The section that lists every principal, or a line saying there are none
/// besides the owner. `now` is the instant in Unix milliseconds the ages are
/// counted from, `armed` is the revocation the owner has armed, if any, and
/// `more` says whether the catalogue holds more rows than the page lists.
///
/// ## Examples
///
/// ```gleam
/// // admin_people.principals(rows, grants.Whole, logins, None, now, None, presses, admin_buttons.Free)
/// ```
pub fn principals(
  rows: List(Principal),
  more: grants.More,
  logins: List(Logins),
  this: Option(String),
  now: Int,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.section(
    [attribute.class("admin-section"), attribute.aria_label("Principals")],
    [
      heading("People", list.length(rows)),
      html.ul(
        [attribute.class("admin-list")],
        list.map(rows, fn(row) {
          person(
            row,
            logins_of(logins, row.id),
            this,
            now,
            armed,
            presses,
            busy,
          )
        }),
      ),
      truncation(more),
    ],
  )
}

/// The section that lists the invitations still waiting to be claimed: the
/// principals whose credential state is an open claim.
///
/// ## Examples
///
/// ```gleam
/// // admin_people.pending(rows, None, presses, admin_buttons.Free)
/// ```
pub fn pending(
  rows: List(Principal),
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  let waiting =
    list.filter(rows, fn(row) {
      case row.credential {
        grants.ClaimOpen(..) -> True
        grants.Active(..) | grants.ClaimExpired | grants.NoCredential -> False
      }
    })
  html.section(
    [
      attribute.class("admin-section"),
      attribute.aria_label("Pending invitations"),
    ],
    [
      heading("Pending invitations", list.length(waiting)),
      case waiting {
        [] ->
          html.p([attribute.class("home-empty")], [
            html.text("No invitation is waiting to be claimed."),
          ])
        [_, ..] ->
          html.ul(
            [attribute.class("admin-list")],
            list.map(waiting, fn(row) { invited(row, armed, presses, busy) }),
          )
      },
    ],
  )
}

// The heading of a section: its title and how many rows it holds, as the
// home's workspace heading counts its sessions.
fn heading(title: String, count: Int) -> Element(message) {
  html.h2([attribute.class("home-heading")], [
    html.text(title),
    html.span([attribute.class("home-count")], [html.text(int.to_string(count))]),
  ])
}

// One principal: its name and identity, what it can authenticate with, and, for
// a member, the two changes that are made to a person.
fn person(
  row: Principal,
  logins: Option(Logins),
  this: Option(String),
  now: Int,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.li([attribute.class("admin-row")], [
    html.div([attribute.class("admin-text")], [
      html.span([attribute.class("admin-name")], [
        html.text(row.name),
        html.span([attribute.class("admin-id")], [html.text(row.id)]),
      ]),
      html.span([attribute.class("admin-sub")], [
        html.text(kind_words(row.kind) <> credential_words(row.credential, now)),
      ]),
    ]),
    case row.kind {
      grants.OwnerKind -> element.none()
      grants.MemberKind ->
        html.div([attribute.class("admin-actions")], [
          admin_buttons.plain(
            "Rotate",
            "admin-act",
            presses.ask(grants.Rotate(row.id)),
            busy,
          ),
          revocation(
            row,
            "Revoke access",
            "Revoke " <> row.name <> "'s access",
            armed,
            presses,
            busy,
          ),
        ])
    },
    case logins {
      Some(held) -> sign_ins(row, held, this, now, armed, presses, busy)
      None -> element.none()
    },
  ])
}

// The principal's sign-ins found by the last read, if it has any.
fn logins_of(logins: List(Logins), principal: String) -> Option(Logins) {
  list.find(logins, fn(held) { held.principal == principal })
  |> option.from_result
}

// A principal's browser logins, in a list of their own across the row: each
// with its history and the button that ends it, two steps like every revocation.
// "This browser" marks the one the page was opened from.
fn sign_ins(
  row: Principal,
  held: Logins,
  this: Option(String),
  now: Int,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.div([attribute.class("admin-signins")], [
    html.span([attribute.class("admin-subheading")], [
      html.text("Sign-ins"),
      html.span([attribute.class("home-count")], [
        html.text(int.to_string(held.count)),
      ]),
    ]),
    html.ul(
      [attribute.class("admin-signin-list")],
      list.map(held.shown, fn(signin) {
        sign_in(row, signin, this, now, armed, presses, busy)
      }),
    ),
    case held.count > list.length(held.shown) {
      True ->
        html.p([attribute.class("home-empty")], [
          html.text(
            "More sign-ins exist than this page lists. Run loom access signins to see them.",
          ),
        ])
      False -> element.none()
    },
  ])
}

fn sign_in(
  row: Principal,
  signin: Signin,
  this: Option(String),
  now: Int,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  let here = this == Some(signin.fingerprint)
  html.li([attribute.class("admin-signin")], [
    html.span([attribute.class("admin-text")], [
      html.span([attribute.class("admin-name")], [
        html.text(case here {
          True -> "This browser"
          False -> "Browser"
        }),
        html.span([attribute.class("admin-id")], [
          html.text(signin.fingerprint),
        ]),
      ]),
      html.span([attribute.class("admin-sub")], [
        html.text(signins_view.history(signin, now)),
      ]),
    ]),
    html.div([attribute.class("admin-actions")], [
      admin_buttons.guarded(
        "Revoke sign-in",
        "Revoke this sign-in of " <> row.name,
        grants.RevokeSignin(row.id, signin.fingerprint),
        armed,
        presses,
        busy,
      ),
    ]),
  ])
}

// One waiting invitation: who it is for and how long it has left, with the
// button that voids it.
fn invited(
  row: Principal,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.li([attribute.class("admin-row")], [
    html.div([attribute.class("admin-text")], [
      html.span([attribute.class("admin-name")], [
        html.text(row.name),
        html.span([attribute.class("admin-id")], [html.text(row.id)]),
      ]),
      html.span([attribute.class("admin-sub")], [
        html.text(credential_words(row.credential, 0)),
      ]),
    ]),
    html.div([attribute.class("admin-actions")], [
      revocation(
        row,
        "Void invitation",
        "Void " <> row.name <> "'s invitation",
        armed,
        presses,
        busy,
      ),
    ]),
  ])
}

// The button that revokes a member's credentials and voids its open claim,
// armed by a first press. The people list words it as revoking access and the
// pending list as voiding the invitation, which is the same change.
fn revocation(
  row: Principal,
  label: String,
  sure: String,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  admin_buttons.guarded(
    label,
    sure,
    grants.RevokeCredentials(row.id),
    armed,
    presses,
    busy,
  )
}

// The principal's kind, as the lead of its quiet line.
fn kind_words(kind: grants.Kind) -> String {
  case kind {
    grants.OwnerKind -> "owner · "
    grants.MemberKind -> ""
  }
}

// What the principal can authenticate with, in words.
fn credential_words(credential: Credential, now: Int) -> String {
  case credential {
    grants.Active(fingerprint:, claimed_at_ms: Some(claimed)) ->
      "active · key "
      <> fingerprint
      <> " · joined "
      <> sessions.ago(now, claimed)
    grants.Active(fingerprint:, claimed_at_ms: None) ->
      "active · key " <> fingerprint
    grants.ClaimOpen(expires_in_ms:) ->
      "invited · claim open, " <> minutes(expires_in_ms) <> " left"
    grants.ClaimExpired -> "invitation expired"
    grants.NoCredential -> "no credential"
  }
}

// A lifetime in whole minutes, rounded up, so a claim with a few seconds left
// does not read as none.
fn minutes(milliseconds: Int) -> String {
  int.to_string({ int.max(milliseconds, 0) + 59_999 } / 60_000) <> " min"
}

// The line that says the page lists the first rows only, or nothing.
fn truncation(more: grants.More) -> Element(message) {
  case more {
    grants.Whole -> element.none()
    grants.Truncated ->
      html.p([attribute.class("home-empty")], [
        html.text(
          "More people exist than this page lists. Run loom access list to page through them.",
        ),
      ])
  }
}
