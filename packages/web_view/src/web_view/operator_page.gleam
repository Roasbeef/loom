//// An operator's page: the observer's component, plus the two inputs an
//// operator may send from a browser, a draft and a decision.
////
//// The page socket starts this application only for an attachment whose
//// role, capped by the page's ceiling, is operator (protocol-change/051,
//// the operator addendum). An observer's page is `web_view/component`,
//// whose message type holds no command at all, so which application runs
//// is also which commands exist. The daemon's gateway refuses an
//// observer's mutation on its own; the type is the second, independent
//// layer.
////
//// The inputs are messages, and the component's state stays the
//// observer's: `Observed` passes every observer message through
//// unchanged, and `Submitted`, `Decided` and `Controlled` reach the shared
//// step through `component.submit`, `component.decide` and
//// `component.control`, which wrap them as its commands
//// (`session_view/commands`). A draft is parsed as the terminal parses it,
//// so a slash command that names a session command is that command, and one
//// that opens a terminal surface is refused with a notice. The controls are
//// the same commands chosen by a button or a small form (the goal's
//// buttons, Fork), and `Replying` puts the start of a reply to a
//// peer's message in the composer without sending anything. This module
//// decides nothing about the session. It turns a browser event into one of
//// those calls, and draws the composer, the controls and the approval
//// cards.
////
//// The lane's "Load older" button is the observer's own
//// (`component.OlderRequested`), a read, and reaches this page as an
//// `Observed` message like the rest.
////
//// The browser can reach only the handlers the rendered tree holds, and a
//// handler's message is fixed when the tree is drawn. So each approval
//// button carries the escalation's identity and the sequence it was drawn
//// at, and `component.decide` answers only the record that still has both.
//// The composer is an uncontrolled form: the browser owns the text as the
//// operator types, and one submit carries it to the server, where its
//// fields are decoded totally and anything unexpected refuses the event.

import core/json
import core/origin
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/agent_roster
import session_view/approval
import session_view/operator
import session_view/snapshot
import session_view/turns
import web_view/completion
import web_view/component
import web_view/image
import web_view/invites
import web_view/peer_links
import web_view/remembered
import web_view/sessions
import web_view/view/archiving
import web_view/view/context_breakdown
import web_view/view/controls
import web_view/view/lane
import web_view/view/peer_links as peer_links_view
import web_view/view/remembered as remembered_view
import web_view/view/resume
import web_view/view/share
import web_view/view/shell
import web_view/view/sidebar
import web_view/view/strip
import web_view/view/switch

/// Everything an operator's page can be told.
pub type Msg(socket) {
  /// One of the observer component's own messages: the connection, the
  /// frames and the tick.
  Observed(message: component.Msg(socket))

  /// The composer was submitted with this text, to be sent as a prompt or a
  /// steer, or run as the slash command it names, and with these images,
  /// each the base64 text `<loom-attach>` submitted. The images are the
  /// browser's claim: the daemon decodes them and reads their types from
  /// their bytes (`web_view/image.admit`) before any becomes a command.
  Submitted(text: String, delivery: operator.Delivery, images: List(String))

  /// An approval card's button: the escalation's identity, the sequence
  /// the card was drawn at, and the answer.
  Decided(id: String, seq: Int, answer: component.Answer)

  /// A session control: one of the goal's buttons, or the fork form with
  /// the text it held.
  Controlled(control: component.Control)

  /// A peer message's Reply button, by the key of the piece it was drawn
  /// under. The key is the engine's, never text the peer wrote.
  Replying(key: String)

  /// A sidebar row's button, or a peer message's Open button: the operator
  /// asks to open another session. The identity is the catalogue's, drawn
  /// into the tree by the server, never text the browser sent or the peer
  /// wrote. The daemon decides whether the page's principal may have it
  /// (protocol-change/051, the addendum on switching sessions).
  Opening(session: String)

  /// A saved sidebar row's button: the operator asks the daemon to resume that
  /// session and open its page (protocol-change/065, the third pull request).
  /// The identity is the catalogue's, as for `Opening`, and the daemon checks
  /// the page's ceiling and the principal's role in the session before it opens
  /// anything.
  Resuming(session: String)

  /// One of the invitation control's two buttons: the owner asks the daemon
  /// to invite a person to this session, in the role the button names. The
  /// role is the message's, fixed when the tree was drawn, and the control is
  /// drawn only on an owner's page (protocol-change/051, the addendum on
  /// inviting from the session page).
  Inviting(role: invites.Role)

  /// The invitation control's "Hide the token" button: the owner has copied
  /// the invitation and the page drops it.
  Dismissing

  /// The rename control's submit: the owner asks the daemon to give this
  /// page's session the name the field held. The name is the browser's text and
  /// nothing else is: the session, the principal and the right to rename are
  /// the daemon's, read again when the request runs (protocol-change/067). The
  /// control is drawn only on an owner's page.
  Renaming(name: String)

  /// The "Make shareable" button of a private session: the owner asks to be
  /// asked. The page replaces the button with a question and changes nothing
  /// else, so nothing the browser can send before the confirm touches the
  /// session. It is drawn only on an owner's page.
  AskingShareable

  /// The question's Cancel: the button comes back.
  CancellingShareable

  /// The question's confirm: the owner asks the daemon to stop the session, move
  /// it to its own history and resume it. The page sends it to the daemon only
  /// from the question (`component.make_shareable`), and the daemon decides again
  /// whether the page's principal is the owner.
  MakingShareable

  /// A sidebar row's archive button: the page opens that row's question and
  /// sends nothing. The identity is the catalogue's, and which action the
  /// question is for is the row's residency in the page's list, never the
  /// message (protocol-change/065, the addendum on archiving from the sidebar).
  AskingArchive(session: String)

  /// The sidebar question's confirm: the page asks the daemon, only for the row
  /// and the action that question was opened for.
  ConfirmingArchive(session: String)

  /// The sidebar question's Cancel.
  CancellingArchive

  /// A Forget button of the remembered-permissions list, with the question
  /// it asks: the request as the list looked when the button was drawn. The
  /// page opens the question and sends nothing (protocol-change/073).
  AskingForget(armed: remembered.Armed)

  /// The question's confirm: the page sends the forget that question armed,
  /// and nothing else, through the shared step like any other command.
  ConfirmingForget

  /// The question's Keep: the page closes it and sends nothing.
  CancellingForget

  /// A button of the owner's peer-link section (protocol-change/077). It
  /// carries what the server drew on the button, and the component checks it
  /// against its own board and sidebar list again before it acts. The section
  /// is drawn only on an owner's page.
  Peering(press: peer_links.Press)

  /// The peer-link section's Link form was submitted with this text as the
  /// strand in the other session. The text is the browser's and nothing else
  /// is: the strand the link leaves, the session it goes to and what it allows
  /// are the page's state, and the right to link is the daemon's.
  Linking(strand: String)
}

/// The Lustre application for one session's operator page.
///
/// ## Examples
///
/// ```gleam
/// // lustre.start_server_component(operator_page.app(), start)
/// ```
pub fn app() -> lustre.App(
  component.Start(socket),
  component.Model(socket),
  Msg(socket),
) {
  lustre.application(init, update, view)
}

fn init(
  start: component.Start(socket),
) -> #(component.Model(socket), Effect(Msg(socket))) {
  let #(model, effects) = component.init(start)
  #(model, effect.map(effects, Observed))
}

/// Applies one message.
///
/// ## Examples
///
/// ```gleam
/// // operator_page.update(model, operator_page.Submitted("hi", operator.Prompt))
/// ```
pub fn update(
  model: component.Model(socket),
  message: Msg(socket),
) -> #(component.Model(socket), Effect(Msg(socket))) {
  let before = component.notice(model)
  let held = model
  let #(model, effects) = case message {
    Observed(message:) -> component.update(model, message)
    Submitted(text:, delivery:, images:) ->
      component.submit(model, text, delivery, images)
    Decided(id:, seq:, answer:) -> component.decide(model, id, seq, answer)
    Controlled(control:) -> component.control(model, control)
    Replying(key:) -> component.reply(model, key)
    Opening(session:) -> component.switch_to(model, session)
    Resuming(session:) -> component.resume(model, session)
    Inviting(role:) -> component.invite(model, role)
    Dismissing -> #(component.dismiss_invitation(model), effect.none())
    AskingShareable -> #(component.arm_shareable(model), effect.none())
    CancellingShareable -> #(component.disarm_shareable(model), effect.none())
    MakingShareable -> component.make_shareable(model)
    Renaming(name:) -> component.renaming(model, name)
    AskingArchive(session:) -> #(
      component.ask_archive(model, session),
      effect.none(),
    )
    ConfirmingArchive(session:) -> component.confirm_archive(model, session)
    CancellingArchive -> #(component.cancel_archive(model), effect.none())
    AskingForget(armed:) -> #(component.ask_forget(model, armed), effect.none())
    ConfirmingForget -> component.confirm_forget(model)
    CancellingForget -> #(component.cancel_forget(model), effect.none())
    Peering(press:) -> component.peering(model, press)
    Linking(strand:) -> component.linking(model, strand)
  }

  // The list of what the session remembers is this page's to read, and the
  // read is owed on the page's own cadence. When a read has changed it, the
  // daemon is asked which of the sign-ins it names have since ended.
  let #(model, judged) =
    component.judge_logins(held, component.want_permissions(model))
  let effects = effect.batch([effects, judged])

  // A notice that changed is a new element, which fades from the start. One
  // that did not is left alone, so a background refresh does not restart the
  // fade of the words already on screen.
  let model = case component.notice(model) == before {
    True -> model
    False -> component.renew_notice(model)
  }
  #(model, effect.map(effects, Observed))
}

/// The operator's page: the heading, the agent strip, the lane, and the
/// dock, which holds the todo panel, the session controls, the approvals
/// waiting for a decision, in a region of their own directly above the
/// composer, and the composer. The advisor's pending nudges are not in
/// the dock: the strand panel carries them (`component.panel`), so the
/// dock holds only what the operator types into or answers.
///
/// The page is a fixed frame: the heading and the agent strip at the top,
/// the dock at the bottom, and the lane between them as the one thing that
/// scrolls (`<loom-follow>`). In the document's flow the composer moved
/// down every time a row landed or its editor grew, so a click aimed at
/// Send or Steer could land on whatever had slid under the pointer. In the
/// frame the dock stays where the operator last saw it however the
/// transcript moves.
///
/// The approvals are in the dock so that a pending card is on screen
/// wherever the operator has scrolled. They sit above the composer, and the
/// dock is pinned by its bottom edge, so a card appearing grows the dock
/// upward and leaves the composer's controls where they were: the agent
/// decides when an escalation lands and how tall its card is, and neither
/// can move Send or Steer. The region's height is capped by the stylesheet
/// and scrolls on its own, so a 16 KiB action preview cannot push the
/// composer off the screen.
///
/// The todo panel is the dock's first child, above the approvals. It is the
/// terminal's pinned board and reviewer band, drawn by `component.plan`, and
/// like the approvals it grows the dock upward, shrinks the transcript by as
/// much and is capped by the stylesheet, so the panel can neither move the
/// composer nor cover a transcript row. With no board and no reviewer it is
/// `element.none()`, as the approvals are.
///
/// The nudges card moved to the panel and the controls lost Stop and the
/// Set goal form: the dock reads as a composer with the session's pending
/// decisions above it, and the goals and forks the bar still offers are
/// the ones the operator acts on while a goal is pinned (`web_view/view/
/// controls`). A peer's message in the lane carries a Reply button
/// (`lane.view`). All are capped or drawn at fixed places, so none can
/// move the composer's controls.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(operator_page.view(model))
/// ```
pub fn view(model: component.Model(socket)) -> Element(Msg(socket)) {
  shell.view(
    shell.Operator,
    component.heading(
      model,
      Observed(component.GoingHome),
      context_breakdown.Actions(
        refresh: Observed(component.ContextRefreshRequested),
        compact: Some(Controlled(component.CompactStrand)),
      ),
    ),
    sidebar_place(model),
    [
      component.crumb(model),
      lane.view(
        component.pieces(model),
        component.live(model),
        component.top(model),
        Observed(component.OlderRequested),
        lane.Replies(reply: Replying, open: fn(session) {
          openable(model, session)
        }),
        component.marks(model),
        lane.Folds(fn(fold) { Observed(component.FoldToggled(fold)) }),
        component.session_id(model),
      ),
      html.footer([attribute.class("dock")], [
        component.plan(model),
        controls.dock(bar(model)),
        approvals(
          component.pending(model),
          component.raised_on(model),
          component.may_remember(model),
        ),
        composer(model),
      ]),

      // The element that moves the browser to another page is always the
      // centre's last child, so no admitted path moves with it.
      component.switch(model),
      switch.switcher(),
    ],
    component.panel(
      model,
      fn(strand) { Observed(component.FocusRequested(strand)) },
      Some(component.viewers(model)),
      share.view(
        component.share(model),
        component.moving(model),
        share.Presses(
          observer: Inviting(invites.Observer),
          operator: Inviting(invites.Operator),
          done: Dismissing,
          make: AskingShareable,
          confirm: MakingShareable,
          cancel: CancellingShareable,
        ),
      ),
      controls.session(bar(model)),
      component.rename_form(model, form_submit_text(Renaming)),
      case component.may_remember(model) {
        True ->
          remembered_view.view(
            component.permissions_kept(model),
            component.permissions_state(model),
            remembered_view.Presses(
              ask: AskingForget,
              confirm: ConfirmingForget,
              cancel: CancellingForget,
            ),
          )
        False -> element.none()
      },
      component.peer_links_section(
        model,
        peer_links_view.Presses(
          press: Peering,
          submit: form_submit_text(Linking),
        ),
      ),
    ),
    component.needing(model),
    component.workspace_digest(model),
  )
}

// The sidebar's place in the frame. A page whose catalogue read listed
// nothing has no sidebar to draw, and the frame is told so, so that its bar
// draws no button that would hide an empty column.
fn sidebar_place(model: component.Model(socket)) -> shell.Sidebar(Msg(socket)) {
  case component.session_groups(model) {
    [] -> shell.Unlisted
    groups ->
      shell.Listed(sidebar.view(
        groups,
        component.session_id(model),
        component.session_activity(model),
        Opening,
        resume.Offered(Resuming, component.resuming_session(model)),
        archive_offer(model),
      ))
  }
}

// What the sidebar offers for archiving a row: the quiet button and its
// question on a page the daemon handed the capability, and nothing otherwise.
fn archive_offer(
  model: component.Model(socket),
) -> archiving.Archiving(Msg(socket)) {
  case component.may_archive(model) {
    True ->
      archiving.Offered(
        ask: AskingArchive,
        confirm: ConfirmingArchive,
        cancel: CancellingArchive,
        stage: component.archive_stage(model),
      )
    False -> archiving.Never
  }
}

// The Open button of a peer message that names a session the page can open,
// or none. The name and the identity in the button are the catalogue's entry,
// found by the identity the peer's message carries.
fn openable(
  model: component.Model(socket),
  session: String,
) -> Option(lane.Destination(Msg(socket))) {
  component.openable(model, session)
  |> option.map(fn(entry) {
    lane.Destination(label: sessions.label(entry), press: Opening(entry.id))
  })
}

// The controls, with what each sends. The fork form sends its text as one
// field. The bar is drawn in the dock for an operator only: an observer's
// page has no message for any of it.
fn bar(model: component.Model(socket)) -> controls.Bar(Msg(socket)) {
  controls.Bar(
    goal: component.goal(model),
    pause: Controlled(component.PauseGoal),
    resume: Controlled(component.ResumeGoal),
    clear: Controlled(component.ClearGoal),
    fork: form_submit(component.Fork),
    sent: component.sent_forms(model),
  )
}

// A control form's submit, carrying the one field it has. Anything else in
// the form refuses the event, as the composer's decoder refuses an unknown
// field.
fn form_submit(
  control: fn(String) -> component.Control,
) -> attribute.Attribute(Msg(socket)) {
  event.on("submit", written(control)) |> event.prevent_default
}

// A form's submit as the message `to_message` makes of its one text field, with
// the same total decoding the control forms have: exactly one field, named
// `text`.
fn form_submit_text(
  to_message: fn(String) -> Msg(socket),
) -> attribute.Attribute(Msg(socket)) {
  event.on("submit", written_text(to_message)) |> event.prevent_default
}

fn written_text(
  to_message: fn(String) -> Msg(socket),
) -> decode.Decoder(Msg(socket)) {
  use fields <- decode.subfield(["detail", "formData"], decode.list(field()))
  case control_text(fields) {
    Ok(text) -> decode.success(to_message(text))
    Error(Nil) -> decode.failure(to_message(""), "text form")
  }
}

fn written(
  control: fn(String) -> component.Control,
) -> decode.Decoder(Msg(socket)) {
  use fields <- decode.subfield(["detail", "formData"], decode.list(field()))
  case control_text(fields) {
    Ok(text) -> decode.success(Controlled(control(text)))
    Error(Nil) -> decode.failure(Controlled(control("")), "control form")
  }
}

/// The text of a submitted control form's fields, or a refusal: exactly one
/// field, named `text`, and nothing else.
///
/// ## Examples
///
/// ```gleam
/// assert operator_page.control_text([#("text", "try-a-cache")])
///   == Ok("try-a-cache")
/// ```
pub fn control_text(fields: List(#(String, String))) -> Result(String, Nil) {
  case fields {
    [#("text", text)] -> Ok(text)
    _ -> Error(Nil)
  }
}

/// The attribute that marks the region of approval cards. `<loom-shell>`'s key
/// listener drops every key pressed inside a region that carries it, so no
/// shortcut acts near a card (protocol-change/051, the addendum on the
/// keyboard). The word is fixed here and never comes from the session.
pub const approvals_marker = "loom-approvals"

// The approvals region sits outside the transcript, so nothing the session
// writes can appear inside it, and it is styled unlike any transcript line.
// A card is keyed by the sequence its record was drawn at, which is the
// daemon's and never text the session wrote. Every storage write takes its
// own sequence, so no two pending records share one, and a card keeps its
// key when a sibling leaves. A card never takes focus and nothing here has
// `autofocus`.
//
// With nothing pending the region is `element.none()`, an empty text node,
// rather than nothing at all. The composer therefore stays the dock's
// last child, after the places of the todo panel, the controls
// and this one, whether or not a card is drawn, so the path a browser event
// names for the composer's form is the same before and after a card
// appears, and a submit in flight still reaches the form.
fn approvals(
  pending: List(approval.Review),
  raised_on: List(#(String, String)),
  owner: Bool,
) -> Element(Msg(socket)) {
  case pending {
    [] -> element.none()
    [_, ..] ->
      html.section(
        [
          attribute.class("approvals"),
          attribute.aria_label("Approvals waiting"),
          attribute.data(approvals_marker, ""),
        ],
        [
          keyed.div(
            [attribute.class("approval-list")],
            list.map(pending, fn(record) {
              #(int.to_string(record.seq), card(record, raised_on, owner))
            }),
          ),
        ],
      )
  }
}

// One card, drawn from the escalation record alone. Deny comes first, so it
// is the first control the operator reaches by tabbing into the card; each
// button names the tool it answers; and Allow is offered only when the
// record's whole authority was captured, which `approval.presentation`
// decides.
//
// The header says who waits and what for, as a sentence: the strand's name,
// which is session text and a text node, then `approval.wants`, a fixed table
// of words for the harness's own tools. The question is the quiet line under
// it.
//
// The action row carries `arming`, which the stylesheet uses to refuse
// clicks on the row for 600 ms after the card is inserted, with the buttons
// drawn dimmed and the row's note, `Arming…`, shown meanwhile. A card appears
// above the composer when the agent decides, so a click already on its way to
// the bottom of the transcript could otherwise land on Allow. The delay is a
// CSS animation, so it needs no script and no timer here, and it runs once
// per inserted card: cards are keyed by sequence, so a later patch updates
// the same node rather than inserting a new one, and the animation does not
// start again.
fn card(
  record: approval.Review,
  raised_on: List(#(String, String)),
  owner: Bool,
) -> Element(Msg(socket)) {
  let tool = case record.tool {
    "" -> "this request"
    tool -> tool
  }
  let deny =
    button(
      "approval-deny",
      "Deny " <> tool,
      Decided(record.id, record.seq, component.Deny),
    )
  let head =
    html.p([attribute.class("approval-head")], [
      html.b([attribute.class("approval-strand")], [
        html.text(case list.key_find(raised_on, record.id) {
          Ok(strand) -> strand
          Error(Nil) -> "A strand"
        }),
      ]),
      html.text(" wants to " <> approval.wants(record.tool)),
    ])
  let arming = html.span([attribute.class("arm-note")], [html.text("Arming…")])
  case approval.presentation(record) {
    Ok(shown) ->
      html.article([attribute.class("approval-card")], [
        head,
        html.p([attribute.class("approval-question")], [
          html.text(shown.question),
        ]),
        html.pre([attribute.class("approval-action")], [html.text(shown.action)]),
        html.ul(
          [attribute.class("approval-authority")],
          list.map(shown.authority, fn(line) {
            // The terminal's lines carry their own dash, and a list item
            // draws its own marker.
            html.li([], [html.text(string.drop_start(line, 2))])
          }),
        ),
        html.div(
          [attribute.class("approval-actions"), attribute.class("arming")],
          [
            deny,
            button(
              "approval-allow",
              "Allow " <> tool <> " once",
              Decided(record.id, record.seq, component.AllowOnce),
            ),
            ..session_offer(record, tool, arming, owner)
          ],
        ),
      ])
    Error(reason) ->
      html.article([attribute.class("approval-card")], [
        head,
        html.p([attribute.class("approval-question")], [
          html.text("This request cannot be approved from the page: " <> reason),
        ]),
        html.div(
          [attribute.class("approval-actions"), attribute.class("arming")],
          [deny, arming],
        ),
      ])
  }
}

// What follows "Allow once" on a card whose request can be remembered: the
// button that remembers it, which names the tool as the one before it does,
// and the arming note. A request the terminal could not remember either
// (`approval.rememberable`: a limit, an environment variable, scratch space,
// or a grant set that is not whole) offers only the note. The same rule is
// asked again when the button is pressed (`component.decide`), so a card drawn
// from a record that has since moved cannot remember what it did not show.
fn session_offer(
  record: approval.Review,
  tool: String,
  arming: Element(Msg(socket)),
  owner: Bool,
) -> List(Element(Msg(socket))) {
  case owner, approval.rememberable(record) {
    True, Ok(Nil) -> [
      button(
        "approval-allow",
        "Allow " <> tool <> " for this session",
        Decided(record.id, record.seq, component.AllowForSession),
      ),
      arming,
    ]
    True, Error(_) | False, _ -> [arming]
  }
}

fn button(
  class: String,
  label: String,
  message: Msg(socket),
) -> Element(Msg(socket)) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class(class),
      event.on_click(message),
    ],
    [html.text(label)],
  )
}

// The composer, as a card of three rows: whom it addresses, the editor, and
// a footer holding the hint, the attach button, who the page acts as and the
// actions. The editor is uncontrolled and keyed by how many drafts have been
// sent, so a sent draft is replaced by an empty editor and a refused one
// stays as the operator left it. The attach element is keyed the same way, so
// a sent draft leaves with its attachments, and it sits in the footer so its
// button is the footer's icon. The only handler is the form's submit; Enter in
// the editor is a newline, never a submission and never a decision.
fn composer(model: component.Model(socket)) -> Element(Msg(socket)) {
  let sent = int.to_string(component.drafts(model))
  html.form(
    [
      attribute.class("composer"),
      attribute.aria_label("Composer"),
      event.on("submit", composed()) |> event.prevent_default,
    ],
    [
      addressing(model),
      keyed.div([attribute.class("editor")], [
        #("draft-" <> sent, draft(model)),
      ]),
      html.div([attribute.class("composer-actions")], [
        keyed.div([attribute.class("attach-slot")], [
          #("attach-" <> sent, attach()),
        ]),
        html.span([attribute.class("hint")], [
          html.text(hint(component.activity(model))),
        ]),
        keyed.div([attribute.class("notice-slot")], [
          #(
            int.to_string(component.notice_serial(model)),
            notice(component.notice(model)),
          ),
        ]),
        html.span([attribute.class("foot-space")], []),
        who(model),
        outlook(component.addressed(model)),
        ..actions(component.activity(model))
      ]),
    ],
  )
}

// The footer's hint: the key that sends, and that the turn is busy when it
// is.
fn hint(activity: component.Activity) -> String {
  case activity {
    component.Idle -> "Cmd+Enter to send"
    component.Busy -> "Turn is busy · Cmd+Enter to send"
  }
}

// The element that attaches images to the draft. `<loom-attach>` is
// form-associated, so its images join the form as one field named `images`,
// in the same submit as the draft (protocol-change/051, the addendum on
// images). Its `limits` attribute is the daemon's own numbers and media types
// (`web_view/image.limits_attribute`) and holds no session text.
fn attach() -> Element(Msg(socket)) {
  element.element(
    "loom-attach",
    [
      attribute.name("images"),
      attribute.attribute("limits", image.limits_attribute()),
    ],
    [],
  )
}

// The editor's wrapper: the draft a sent prompt replaces.
fn draft(model: component.Model(socket)) -> Element(Msg(socket)) {
  html.div([attribute.class("draft")], [editor(model)])
}

// The editor, inside `<loom-composer>` (`packages/web_client`), which lists
// the slash commands as the draft grows and sends it on Command or Control
// with Enter. The textarea is still the uncontrolled editor it was, and the
// element only listens to it: the browser owns the text, the form's submit is
// the one event the server hears, and Enter in the editor is a newline. The
// element's `commands` attribute is the static table of completions, which
// holds no session text (`web_view/completion`).
//
// A prompt the daemon handed back is put in the editor by the element, which
// alone knows whether the operator has typed there since. The server tells it
// with the count in `returned`, which rises with each return, and with the
// prompts themselves as text-node children in the slot named `returned`,
// each numbered by a `data-n`. The element's shadow root has no such slot,
// so the browser never draws them; they are only read. They come after the
// textarea, so the textarea keeps its place in the tree.
//
// `refused` is how many submits were refused with the draft kept
// (`component.refusals`), the page's own refusals and the lane's. The element
// shows a sent draft as a pending line until the server takes it, which
// replaces the element, or refuses it, which the rising count says; it then
// puts the draft back (`web_client/pending_rule`). A notice that keeps the
// draft without refusing it, the lane holding a send until a read answers, is
// not counted, so the line stays until the send.
fn editor(model: component.Model(socket)) -> Element(Msg(socket)) {
  let returns = component.returns(model)
  let returned = component.returned(model)
  let refusals = component.refusals(model)

  // Provider fragments do not change the editor. Keep its command table and
  // returned drafts until an editor input changes, and capture only those
  // inputs rather than the page's session and transport in the memo.
  use <- element.memo([
    element.ref(returns),
    element.ref(returned),
    element.ref(refusals),
  ])
  element.element(
    "loom-composer",
    [
      attribute.attribute("commands", completion.table()),
      attribute.attribute("returned", int.to_string(returns)),
      attribute.attribute("refused", int.to_string(refusals)),
    ],
    [
      html.textarea(
        [
          attribute.name("draft"),
          attribute.rows(3),
          attribute.aria_label("Message the agent"),
          attribute.placeholder("Message the agent"),
        ],
        "",
      ),
      ..list.map(returned, fn(returned) {
        html.span(
          [
            attribute.attribute("slot", "returned"),
            attribute.attribute("data-n", int.to_string(returned.number)),
          ],
          [html.text(returned.text)],
        )
      })
    ],
  )
}

// The line above the editor: whom the composer addresses, as a tag in the
// strand's hue. The tag has no handler and no marker, so it is a label and
// not a control; the target menu is ruled out of the page.
fn addressing(model: component.Model(socket)) -> Element(Msg(socket)) {
  html.div([attribute.class("to")], [
    html.span([], [html.text("To")]),
    html.span(
      [
        attribute.class("to-tag"),
        strip.hue_class(hue(model)),
      ],
      [html.text(addressee(model))],
    ),
  ])
}

// The name the page calls the addressed strand by: the one its card carries
// (`agent_roster.short_name`), so a sub-agent is `review-readme` and never
// `sub:main/review-readme-d799cf20a6964d72`. The engine's identity stays in
// nowhere: the name is session text, so it is a text node in the tag and in no attribute.
fn addressee(model: component.Model(socket)) -> String {
  agent_roster.short_name(component.strand(model))
}

fn hue(model: component.Model(socket)) -> turns.Hue {
  component.marks(model).hue
}

// Who the page acts as, from the attachment the last capture was taken for,
// in the footer's quiet type: `Owner · operator`.
fn who(model: component.Model(socket)) -> Element(Msg(socket)) {
  html.span([attribute.class("who")], [
    html.text(case component.attachment(model) {
      None -> "…"
      Some(attachment) ->
        origin.display_label(attachment.origin)
        <> " · "
        <> role_text(attachment.role)
    }),
  ])
}

// The addressed strand's cache outlook, drawn as the chip's ring is and
// worded by `cache_miss.outlook_label`. A tail about to lapse is the one
// reading worth the signal colour; nothing else here nags.
fn outlook(chip: Option(strip.Chip)) -> Element(Msg(socket)) {
  case chip {
    Some(strip.Chip(cache: Some(#(held, label)), ..)) ->
      html.span(
        [
          attribute.class("outlook"),
          strip.ring_class(held),
          attribute.role("status"),
        ],
        [html.text(label)],
      )
    Some(strip.Chip(cache: None, ..)) | None -> element.none()
  }
}

fn role_text(role: snapshot.Role) -> String {
  case role {
    snapshot.Owner -> "owner"
    snapshot.Operator -> "operator"
    snapshot.Observer -> "observer"
  }
}

// An idle strand takes one Send; a busy one takes a Queue, which the daemon
// holds and runs after the current operation, or a Steer, which folds into
// it. Each is a submit button naming its delivery, so the one pressed
// travels with the form.
fn actions(activity: component.Activity) -> List(Element(Msg(socket))) {
  case activity {
    component.Idle -> [submit_button("prompt", "Send", "send")]
    component.Busy -> [
      submit_button("prompt", "Queue", "queue"),
      submit_button("steer", "Steer", "steer"),
    ]
  }
}

fn submit_button(
  delivery: String,
  label: String,
  class: String,
) -> Element(Msg(socket)) {
  html.button(
    [
      attribute.type_("submit"),
      attribute.name("delivery"),
      attribute.value(delivery),
      attribute.class(class),
    ],
    [html.text(label)],
  )
}

fn notice(notice: component.Notice) -> Element(Msg(socket)) {
  case notice {
    component.Quiet ->
      html.p([attribute.class("notice"), attribute.role("status")], [])
    component.Said(text:) ->
      html.p([attribute.class("notice"), attribute.role("status")], [
        html.text(text),
      ])
    component.Warned(text:) ->
      html.p([attribute.class("notice warned"), attribute.role("status")], [
        html.text(text),
      ])
  }
}

// The composer's submit, decoded totally from the form's fields: exactly
// one draft, and at most one delivery, which is `prompt` or `steer`. Any
// other field, a repeated one or an unknown delivery refuses the event, so
// a forged submit cannot smuggle in a command the form does not offer.
fn composed() -> decode.Decoder(Msg(socket)) {
  use fields <- decode.subfield(["detail", "formData"], decode.list(field()))
  case composition(fields) {
    Ok(message) -> decode.success(message)
    Error(Nil) ->
      decode.failure(Submitted("", operator.Prompt, []), "composer form")
  }
}

fn field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The message a submitted composer form's fields stand for, or a refusal.
///
/// The form has three fields and no others: exactly one `draft`, at most one
/// `delivery`, which is `prompt` or `steer`, and at most one `images`, which
/// `<loom-attach>` submits as a JSON array of base64 strings. An `images`
/// that is not that array refuses the event, and so does any other field, a
/// repeated one or an unknown delivery. What the strings hold is not judged
/// here: the daemon decodes them and refuses the ones that are not images
/// with a notice (`component.submit`).
///
/// ## Examples
///
/// ```gleam
/// assert operator_page.composition([#("draft", "hi")])
///   == Ok(operator_page.Submitted("hi", operator.Prompt, []))
/// ```
pub fn composition(
  fields: List(#(String, String)),
) -> Result(Msg(socket), Nil) {
  let drafts = list.filter(fields, fn(field) { field.0 == "draft" })
  let deliveries = list.filter(fields, fn(field) { field.0 == "delivery" })
  let attached = list.filter(fields, fn(field) { field.0 == "images" })
  let others =
    list.filter(fields, fn(field) {
      field.0 != "draft" && field.0 != "delivery" && field.0 != "images"
    })
  case drafts, deliveries, attached, others {
    [#(_, text)], _, _, [] -> {
      use images <- result.try(case attached {
        [] -> Ok([])
        [#(_, encoded)] -> image_list(encoded)
        _ -> Error(Nil)
      })
      case deliveries {
        [] -> Ok(Submitted(text, operator.Prompt, images))
        [#(_, "prompt")] -> Ok(Submitted(text, operator.Prompt, images))
        [#(_, "steer")] -> Ok(Submitted(text, operator.Steer, images))
        _ -> Error(Nil)
      }
    }
    _, _, _, _ -> Error(Nil)
  }
}

// The strings of a JSON array of strings, or a refusal for anything else.
fn image_list(encoded: String) -> Result(List(String), Nil) {
  case json.parse(encoded) {
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}
