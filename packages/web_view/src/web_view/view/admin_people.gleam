//// The admin page's list of people: every principal the catalogue holds, each
//// once, with an invitation still waiting to be claimed drawn in its person's
//// own row and not in a second list (round 4, F84).
////
//// A principal's row says who it is and what it can authenticate with, in words
//// the owner can act on: `active` with the fingerprint of the credential and
//// when a claim bound it, `invited` with the time the claim has left,
//// `invitation expired`, or `no credential`. A claim is never drawn, because
//// the catalogue holds only its digest, and a credential only as the first
//// sixteen characters of its own, which is enough to compare with what `loom
//// claim` printed (`web_view/grants`).
////
//// Every row, the owner's included, offers a Rename button (protocol-change/065,
//// the tenth pull request). Pressing it opens a small form in that row, in the
//// words and the shape of the home's rename form: the person's current name is a
//// text node in the form's lead and `<loom-rename>` copies it into the field in
//// the browser, so the name is never a `value`. One form is open at a time. The
//// form is the row's last child, empty when closed, so the row's other children
//// keep their places.
////
//// Each member's row offers the changes the owner makes to a person, not to a
//// session, by what the person holds. A person with an active credential can be
//// rotated, which voids what it held and makes a new claim, or have its
//// credentials revoked, a two-step button (`view/admin_buttons`). A person whose
//// claim is open has one button, `Void invitation`, which is the same
//// revocation worded for what it undoes. A person with neither can be rotated
//// to issue a new claim. The owner's row offers nothing, since the owner's
//// access is not the page's to change, though its name is. The heading counts the people and, when
//// any claim is open, how many are invited.
////
//// A row also holds two slots for what the owner has just done to its person:
//// the line that says it (`view/notice`) and the claim a rotation made
//// (`view/admin_claim`). Both are one child of the row, empty when they do not
//// apply, so the row's other children keep their places.
////
//// A principal that holds browser logins lists them beneath its row, each with
//// the words the home's own list uses and a two-step "Revoke sign-in" button
//// (protocol-change/065, the eighth pull request); the owner's own login the
//// page was opened from is marked "This browser". A principal with more than
//// the page lists says so and leaves the rest to `loom access signins`.
////
//// Every name is a peer's and is drawn as a text node, in a label's words as
//// well. An identity is the catalogue's and is a text node too, shortened to its
//// prefix and eight characters with the whole in the `title`
//// (`grants.short_identity`); nothing here is a class or a key made from
//// either, except as the key of its row: the list is keyed by the catalogue's
//// identity, which is not peer text, so a row that moves, because another
//// principal was listed ahead of it, moves with its claim box and no content is
//// resent. The classes are complete literals.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/grants.{type Claim, type Credential, type Logins, type Principal}
import web_view/sessions
import web_view/signins.{type Signin}
import web_view/view/admin_buttons.{type Busy, type Presses}
import web_view/view/admin_claim
import web_view/view/notice.{type Spoken}
import web_view/view/rename
import web_view/view/signins as signins_view

/// The section that lists every principal, or a line saying there are none
/// besides the owner. `now` is the instant in Unix milliseconds the ages are
/// counted from, `armed` is the revocation the owner has armed, if any, `more`
/// says whether the catalogue holds more rows than the page lists, `spoken` is
/// the last thing the page said about an ask, and `claim` is the claim on screen,
/// if one is. A row draws the line and the claim only when they are about its
/// principal. `editing` is the principal whose rename form is open, if one is.
///
/// ## Examples
///
/// ```gleam
/// // admin_people.principals(rows, grants.Whole, logins, None, now, None, None, None, None, presses, admin_buttons.Free)
/// ```
pub fn principals(
  rows: List(Principal),
  more: grants.More,
  logins: List(Logins),
  this: Option(String),
  now: Int,
  armed: Option(grants.Action),
  spoken: Option(Spoken),
  claim: Option(Claim),
  editing: Option(String),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.section(
    [attribute.class("admin-section"), attribute.aria_label("Principals")],
    [
      heading(rows),
      keyed.ul(
        [attribute.class("admin-list")],
        list.map(rows, fn(row) {
          #(
            row.id,
            person(
              row,
              logins_of(logins, row.id),
              this,
              now,
              armed,
              spoken,
              claim,
              editing,
              presses,
              busy,
            ),
          )
        }),
      ),
      truncation(more),
    ],
  )
}

// The heading: "People", how many the page lists, and, when any claim is open,
// how many of them are invited, all as the home's workspace heading counts its
// sessions.
fn heading(rows: List(Principal)) -> Element(message) {
  let invited =
    list.count(rows, fn(row) {
      case row.credential {
        grants.ClaimOpen(..) -> True
        grants.Active(..) | grants.ClaimExpired | grants.NoCredential -> False
      }
    })
  html.h2([attribute.class("home-heading")], [
    html.text("People"),
    html.span([attribute.class("home-count")], [
      html.text(int.to_string(list.length(rows))),
    ]),
    case invited {
      0 -> element.none()
      _ ->
        html.span([attribute.class("home-count")], [
          html.text("· " <> int.to_string(invited) <> " invited"),
        ])
    },
  ])
}

// One principal: its name and identity, what it can authenticate with, and, for
// a member, the changes that are made to a person, by what it holds.
fn person(
  row: Principal,
  logins: Option(Logins),
  this: Option(String),
  now: Int,
  armed: Option(grants.Action),
  spoken: Option(Spoken),
  claim: Option(Claim),
  editing: Option(String),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  html.li([attribute.class("admin-row")], [
    html.div([attribute.class("admin-text")], [
      html.span([attribute.class("admin-name")], [
        html.text(row.name),
        identity(row.id),
      ]),
      html.span([attribute.class("admin-sub")], [
        html.text(kind_words(row.kind) <> credential_words(row.credential, now)),
      ]),
    ]),
    html.div([attribute.class("admin-actions")], [
      admin_buttons.plain("Rename", "admin-act", presses.edit(row.id), busy),
      ..case row.kind {
        grants.OwnerKind -> []
        grants.MemberKind -> actions(row, armed, presses, busy)
      }
    ]),
    case logins {
      Some(held) -> sign_ins(row, held, this, now, armed, presses, busy)
      None -> element.none()
    },
    notice.at_person(spoken, row.id),
    admin_claim.for_person(claim, row.id, presses.dismiss),
    rename_form(row, editing, presses, busy),
  ])
}

// The row's rename form, when it is the one that is open, and the empty node that
// keeps its place otherwise. The person's name is a text node in the lead and
// `<loom-rename>` copies it into the field in the browser; the field is
// uncontrolled and the one submit sends its text under the name `text`. While a
// request is out the buttons are disabled, though the handler stays, because the
// component is the layer that ignores a second one.
fn rename_form(
  row: Principal,
  editing: Option(String),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  case editing {
    Some(open) if open == row.id -> {
      let locked = case busy {
        admin_buttons.Free | admin_buttons.Spent(_) -> []
        admin_buttons.Occupied -> [attribute.disabled(True)]
      }
      html.form(
        [
          attribute.class("admin-rename"),
          attribute.aria_label("Rename this person"),
          attribute.attribute(rename.scope_marker, ""),
          presses.rename(row.id),
        ],
        [
          html.p([attribute.class("admin-lead")], [
            html.text("Rename "),
            html.span([attribute.attribute(rename.name_marker, "")], [
              html.text(row.name),
            ]),
          ]),
          html.div([attribute.class("admin-fields")], [
            rename.field(),
            html.button(
              [
                attribute.type_("submit"),
                attribute.class("admin-act"),
                ..locked
              ],
              [html.text("Rename")],
            ),
            html.button(
              [
                attribute.type_("button"),
                attribute.class("admin-act"),
                event.on_click(presses.cancel),
                ..locked
              ],
              [html.text("Cancel")],
            ),
          ]),
        ],
      )
    }
    Some(_) | None -> element.none()
  }
}

/// A principal's identity drawn as its short form, with the whole in the
/// `title`. The page's other lists draw their identities the same way.
///
/// ## Examples
///
/// ```gleam
/// // admin_people.identity("owner-2056528fe1be0db0f7105a24da3aac4d")
/// ```
pub fn identity(id: String) -> Element(message) {
  html.span([attribute.class("admin-id"), attribute.title(id)], [
    html.text(grants.short_identity(id)),
  ])
}

// The buttons of a member's row, by what the member holds: a person with a
// credential can be rotated or revoked, a person with an open claim can only
// have it voided, and a person with neither can be given a new claim.
fn actions(
  row: Principal,
  armed: Option(grants.Action),
  presses: Presses(message),
  busy: Busy,
) -> List(Element(message)) {
  let rotate =
    admin_buttons.granting(
      "Rotate",
      "admin-act",
      presses.ask(grants.Rotate(row.id)),
      busy,
    )
  case row.credential {
    grants.Active(..) -> [
      rotate,
      revocation(
        row,
        "Revoke access",
        "Revoke " <> row.name <> "'s access",
        armed,
        presses,
        busy,
      ),
    ]
    grants.ClaimOpen(..) -> [
      revocation(
        row,
        "Void invitation",
        "Void " <> row.name <> "'s invitation",
        armed,
        presses,
        busy,
      ),
    ]
    grants.ClaimExpired | grants.NoCredential -> [rotate]
  }
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
  let whose = signins_view.whose(signin, this)
  html.li([attribute.class("admin-signin")], [
    html.span([attribute.class("admin-text")], [
      html.span([attribute.class("admin-name")], [
        html.text(case whose {
          signins_view.ThisBrowser -> "This browser"
          signins_view.AnotherBrowser -> "Browser"
        }),
        html.span([attribute.class("admin-id")], [
          html.text(signin.fingerprint),
        ]),
      ]),
      html.span([attribute.class("admin-sub")], [
        html.text(signins_view.history(signin, now, whose)),
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

// The button that revokes a member's credentials and voids its open claim,
// armed by a first press. A person with a credential reads it as revoking
// access and a person with an open claim as voiding the invitation, which is
// the same change.
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
