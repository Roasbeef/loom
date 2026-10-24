//// The strand panel's Evolution tab, drawn on an operator's page
//// (protocol-change/099).
////
//// A session proposes an extension, a program or a prompt, tests it, and a
//// person approves it and selects it as the generation the session runs. The
//// tab lists the candidates by kind, each as a tinted box with a hairline
//// border: its name and short identity, where it stands, what it does, the
//// evidence retained for it and who approved it. Above them it says what is
//// live now, and below them it lists the decisions made, newest first, and a
//// read-only card for the core component.
////
//// A row offers the changes `web_view/evolution` says the page may offer, and
//// each is two presses. The first button opens a question in the row, a tinted
//// block that names the candidate, the evidence and the generation as the page
//// drew them, and sends nothing. The question's confirm sends that change and
//// no other. A selection that has been accepted shows `staging…` on its row
//// from the lane's own tracker (`session_view/evolution_pending`), and the lane's
//// polling redraws the row as the daemon reports, so no request identity is
//// ever drawn.
////
//// There is no left-edge bar and no shadow. Core upgrades and downgrades are
//// not drawn: the daemon admits them to the native owner alone, and the card
//// says to use the terminal.
////
//// Every name, description, reason, principal and identity comes from a model
//// or from a catalogue it wrote. Each is drawn as a text node. None is an
//// attribute, a class, a key or a handler's message: a handler carries the
//// change the server drew on the button from its own board, a value held by
//// the page's server and never read back from the browser, and the classes
//// are literals chosen from closed sets.
////
//// ## Flow
////
//// `view` is the pane. It draws the notice, the `live` summary, one `group`
//// for each kind of candidate (each row through `candidate`, which draws the
//// `staging_line`, the `evidence` rows, the `actions` and the open
//// `question`), the `history` and the `core_card`.

import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/evolution
import session_view/evolution_pending
import web_view/evolution as evolving
import web_view/view/home_table

/// How many history entries the tab draws. The board holds more; the rest are
/// counted in a sentence.
pub const history_shown = 12

/// The messages the tab's buttons send.
pub type Presses(message) {
  Presses(
    /// A change's button, with the change as the page drew it. The press opens
    /// the question and sends nothing.
    ask: fn(evolving.Armed) -> message,
    /// The confirm of an approval's question, which has no field.
    approve: message,
    /// The submit handler of the other questions' form, which carries the
    /// reason field's text.
    submit: attribute.Attribute(message),
    /// A question's way out, which closes it and sends nothing.
    keep: message,
    /// The "Read again" button.
    read: message,
    /// The core card's button, which asks for the component's status.
    core: message,
  )
}

/// Whether the tab draws the core component's card. A member operator's page
/// does not: the daemon refuses `core_status` to anyone but its owner.
pub type Core {
  /// No card.
  NoCard

  /// The card, with the status the page last read, if it has read one.
  Card(opened: Option(evolution.Opened))
}

/// What the tab draws from. The page assembles it from the shared record and
/// its own state; the tab reads nothing else.
pub type Page {
  Page(
    /// The board for this session, or `None` while it is unread or the page
    /// holds one for another session.
    board: Option(evolution.Board),
    /// The words of the last outcome or refusal, empty when there is none.
    notice: String,
    /// The question that is open.
    state: evolving.State,
    /// Whose rows the page offers a change on.
    reach: evolving.Reach,
    /// The selections the lane is tracking.
    tracker: evolution_pending.Tracker,
    /// The transport clock's reading, for the time a staging row has left.
    now: Int,
    /// The core component's card.
    core: Core,
  )
}

/// The pane for the page's board: the candidates, that there are none, that
/// the board has not been read, or why it could not be.
///
/// ## Examples
///
/// ```gleam
/// // evolution_view.view(page, presses)
/// ```
pub fn view(page: Page, presses: Presses(message)) -> Element(message) {
  html.section(
    [
      attribute.class("pane"),
      attribute.class("pane-evolution"),
      attribute.class("evolution"),
      attribute.id("evolution"),
      attribute.aria_label("Evolution"),
    ],
    [
      head(page, presses),
      ..list.append(notice(page.notice), body(page, presses))
    ],
  )
}

/// The title, how many wait for a person, and the button that reads the board
/// again. The count is the badge's number, said where the reader who pressed
/// the tab arrives.
fn head(page: Page, presses: Presses(message)) -> Element(message) {
  html.div([attribute.class("evolution-head")], [
    html.h2([attribute.class("panel-title")], [
      html.text(case page.board {
        Some(board) -> title(evolving.waiting(page.reach, board))
        None -> "Evolution"
      }),
    ]),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("evolution-read"),
        event.on_click(presses.read),
      ],
      [html.text("Read again")],
    ),
  ])
}

/// The heading's words for how many wait for a person.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_view.title(0) == "Evolution"
/// assert evolution_view.title(2) == "Evolution · 2 waiting"
/// ```
pub fn title(waiting: Int) -> String {
  case waiting {
    0 -> "Evolution"
    _ -> "Evolution · " <> int.to_string(waiting) <> " waiting"
  }
}

/// The last refusal or outcome, in the words the shared record kept. It is a
/// status for a screen reader, since a selection's outcome arrives on its own.
fn notice(words: String) -> List(Element(message)) {
  case words {
    "" -> []
    _ -> [
      html.p([attribute.class("evolution-notice"), attribute.role("status")], [
        html.text(words),
      ]),
    ]
  }
}

/// A board that has not been read says so, unless a refusal has said why it has
/// not, since "reading" beside a refusal would contradict itself.
fn body(page: Page, presses: Presses(message)) -> List(Element(message)) {
  case page.board, page.notice {
    None, "" -> [quiet(evolution.loading_words)]
    None, _ -> core_card(page, presses)
    Some(board), _ ->
      list.flatten([
        unread(board),
        [live(board)],
        groups(page, board, presses),
        [history(board)],
        core_card(page, presses),
      ])
  }
}

fn quiet(words: String) -> Element(message) {
  html.p([attribute.class("session-quiet")], [html.text(words)])
}

/// The one line that says the board is not the whole of what the daemon sent:
/// rows this client could not read, and candidates the daemon left out to stay
/// within its bound.
fn unread(board: evolution.Board) -> List(Element(message)) {
  let lines =
    list.flatten([
      case board.unread {
        0 -> []
        count -> [
          int.to_string(count) <> " rows could not be read and are not shown.",
        ]
      },
      case board.omitted_candidates {
        0 -> []
        count -> [
          int.to_string(count) <> " older candidates are not shown.",
        ]
      },
    ])
  list.map(lines, quiet)
}

// --- what is live -----------------------------------------------------------

/// The generations the session runs now, one line each, or the sentence that
/// none is selected.
fn live(board: evolution.Board) -> Element(message) {
  let running =
    list.filter(board.selections, fn(selection) {
      selection.liveness == evolution.Live
    })
  html.section(
    [attribute.class("evolution-section"), attribute.aria_label("Live")],
    [
      heading("Live"),
      case running {
        [] -> quiet("Nothing is selected for this session yet.")
        _ ->
          html.ul(
            [attribute.class("evolution-lines")],
            list.map(running, fn(selection) { live_line(board, selection) }),
          )
      },
    ],
  )
}

/// Live line helper.
fn live_line(
  board: evolution.Board,
  selection: evolution.Selection,
) -> Element(message) {
  // Dispatch on live_line state.
  let kind = case evolution.find(board, selection.candidate_id) {
    Ok(candidate) -> evolution.kind_words(candidate.kind)
    Error(Nil) -> "candidate"
  }

  html.li([attribute.class("evolution-line")], [
    html.span([attribute.class("evolution-name")], [html.text(selection.name)]),
    html.text(
      " · "
      <> kind
      <> " · "
      <> evolution.scope_words(selection.scope, board.session)
      <> " · "
      <> evolution.generation_words(selection.generation, selection.liveness),
    ),
  ])
}

fn heading(words: String) -> Element(message) {
  html.h3([attribute.class("session-eyebrow")], [html.text(words)])
}

// --- the candidates ---------------------------------------------------------

/// One section for each kind a candidate can be, in the order extensions,
/// programs, prompts, and a last one for a kind this client cannot name, drawn
/// only when the board holds such a row.
fn groups(
  page: Page,
  board: evolution.Board,
  presses: Presses(message),
) -> List(Element(message)) {
  let known = [
    #("Extensions", evolution.Extension, "No extension candidates."),
    #("Programs", evolution.Program, "No program candidates."),
    #("Prompts", evolution.Prompt, "No prompt candidates."),
  ]
  let drawn =
    list.map(known, fn(entry) {
      let rows =
        list.filter(board.candidates, fn(candidate) {
          candidate.kind == entry.1
        })
      group(page, board, entry.0, rows, entry.2, presses)
    })
  let others =
    list.filter(board.candidates, fn(candidate) {
      !list.contains(
        [evolution.Extension, evolution.Program, evolution.Prompt],
        candidate.kind,
      )
    })

  // Dispatch on groups state.
  case others {
    [] -> drawn
    _ -> list.append(drawn, [group(page, board, "Other", others, "", presses)])
  }
}

/// Group helper.
fn group(
  page: Page,
  board: evolution.Board,
  label: String,
  rows: List(evolution.Candidate),
  empty: String,
  presses: Presses(message),
) -> Element(message) {
  html.section(
    [attribute.class("evolution-section"), attribute.aria_label(label)],
    [
      heading(label <> " (" <> int.to_string(list.length(rows)) <> ")"),
      case rows {
        [] -> quiet(empty)
        _ ->
          html.ul(
            [attribute.class("evolution-list")],
            list.map(rows, fn(row) { candidate(page, board, row, presses) }),
          )
      },
    ],
  )
}

/// One candidate: its facts, its evidence and approval, the staging line when a
/// selection of it is on its way, and what the reader can do about it.
fn candidate(
  page: Page,
  board: evolution.Board,
  row: evolution.Candidate,
  presses: Presses(message),
) -> Element(message) {
  let offers =
    evolving.offers(
      page.reach,
      evolving.staging_of(page.tracker, board),
      board,
      row,
    )
  html.li(
    [attribute.class("evolution-candidate"), standing_class(row)],
    list.flatten([
      [head_line(board, row)],
      description(row),
      [facts(board, row)],
      evidence(row),
      approval(row),
      staging_line(page, board, row),
      [actions(page, offers, presses)],
      question(page, offers, presses),
    ]),
  )
}

/// The class a candidate's standing gives its box: a closed set of literals, so
/// nothing the daemon names can choose one.
fn standing_class(row: evolution.Candidate) -> attribute.Attribute(message) {
  case row.selected, row.approval {
    Some(_), _ -> attribute.class("evolution-selected")
    None, Some(_) -> attribute.class("evolution-approved")
    None, None -> attribute.class("evolution-proposed")
  }
}

/// Head line helper.
fn head_line(
  board: evolution.Board,
  row: evolution.Candidate,
) -> Element(message) {
  html.p([attribute.class("evolution-title-line")], [
    html.span([attribute.class("evolution-name")], [html.text(row.name)]),
    html.span([attribute.class("evolution-id")], [
      html.text(evolution.short_id(row.candidate_id)),
    ]),
    html.span([attribute.class("evolution-state")], [
      html.text(standing_words(board, row)),
    ]),
  ])
}

/// Where a candidate stands, in words: the generation it is, with whether it
/// runs, or whether it has been approved, or that it is still a candidate.
///
/// ## Examples
///
/// ```gleam
/// // evolution_view.standing_words(board, candidate)
/// ```
pub fn standing_words(
  board: evolution.Board,
  row: evolution.Candidate,
) -> String {
  // Dispatch on standing_words state.
  case row.selected, row.approval {
    Some(chosen), _ -> {
      let liveness =
        list.find(board.selections, fn(selection) {
          selection.candidate_id == row.candidate_id
        })
        |> option.from_result
        |> option.map(fn(selection) { selection.liveness })
        |> option.unwrap(evolution.NotLive)
      evolution.generation_words(chosen.generation, liveness)
    }
    None, Some(_) -> "approved, not selected"
    None, None -> "candidate"
  }
}

/// Description helper.
fn description(row: evolution.Candidate) -> List(Element(message)) {
  case row.description {
    "" -> []
    words -> [
      html.p([attribute.class("evolution-description")], [html.text(words)]),
    ]
  }
}

/// Where it applies, what kind it is, what it was proposed from, and whether
/// what was recorded about it was recorded under an evaluator the host no
/// longer runs.
fn facts(board: evolution.Board, row: evolution.Candidate) -> Element(message) {
  // Dispatch on facts state.
  let parent = case row.parent {
    Some(parent) -> [" · proposed from " <> evolution.short_id(parent)]
    None -> []
  }

  // Dispatch on facts state.
  let identity = case row.identity {
    evolution.Current -> []
    evolution.Outdated -> [" · tested under an earlier evaluator"]
  }

  html.p([attribute.class("evolution-meta session-quiet")], [
    html.text(
      string.concat(
        list.flatten([
          [
            evolution.kind_words(row.kind),
            " · ",
            evolution.scope_words(row.scope, board.session),
          ],
          parent,
          identity,
        ]),
      ),
    ),
  ])
}

/// The retained observations, newest first, one line each: why it was made,
/// what it found and when.
fn evidence(row: evolution.Candidate) -> List(Element(message)) {
  case row.evidence {
    [] -> [
      html.p([attribute.class("evolution-meta session-quiet")], [
        html.text("No evidence yet."),
      ]),
    ]
    rows -> [
      html.ul(
        [attribute.class("evolution-evidence")],
        list.map(rows, fn(found) {
          html.li([attribute.class("evolution-evidence-row")], [
            html.text(evidence_words(found)),
          ])
        }),
      ),
    ]
  }
}

/// One observation in words: `author tests · passed · 2026-10-23 14:02 UTC`,
/// with a note when it was made under an evaluator the host no longer runs.
///
/// ## Examples
///
/// ```gleam
/// // evolution_view.evidence_words(found)
/// ```
pub fn evidence_words(found: evolution.Evidence) -> String {
  // Dispatch on evidence_words state.
  let older = case found.identity {
    evolution.Current -> ""
    evolution.Outdated -> " · earlier evaluator"
  }

  "evidence: "
  <> evolution.purpose_words(found.purpose)
  <> " · "
  <> evolution.verdict_words(found.verdict, found.reason)
  <> " · "
  <> stamp(found.at_ms)
  <> older
}

/// Approval helper.
fn approval(row: evolution.Candidate) -> List(Element(message)) {
  // Dispatch on approval state.
  case row.approval {
    None -> []
    Some(approval) -> {
      // Dispatch on approval state.
      let via = case evolution.surface_words(approval.via) {
        "" -> ""
        surface -> " · " <> surface
      }

      [
        html.p([attribute.class("evolution-approval")], [
          html.text(
            "approved by " <> evolution.principal_words(approval.by) <> via,
          ),
        ]),
      ]
    }
  }
}

// The time in UTC, which is all the wire carries.
fn stamp(milliseconds: Int) -> String {
  let #(date, clock) = home_table.utc(milliseconds)
  date <> " " <> clock <> " UTC"
}

// --- a selection on its way -------------------------------------------------

/// The line a selection of this candidate draws while it is on its way and after
/// it settles, until the next board replaces it. The lane's tracker is the
/// source, and the board's own list covers a selection another attachment made,
/// or one the lane lost on a reconnect.
fn staging_line(
  page: Page,
  board: evolution.Board,
  row: evolution.Candidate,
) -> List(Element(message)) {
  case evolution_pending.for_candidate(page.tracker, row.candidate_id) {
    Some(tracked) -> [staging_words(stage_words(tracked, page.now))]
    None ->
      case
        list.any(board.pending, fn(waiting) {
          waiting.candidate_id == row.candidate_id
        })
      {
        True -> [staging_words("staging…")]
        False -> []
      }
  }
}

fn staging_words(words: String) -> Element(message) {
  html.p([attribute.class("evolution-staging"), attribute.role("status")], [
    html.text(words),
  ])
}

/// What a tracked selection says on its row, without the request identity the
/// lane minted: `staging…` while it moves, `committed, publishing…` once it is
/// durable, and how it ended after that.
///
/// ## Examples
///
/// ```gleam
/// // evolution_view.stage_words(tracked, 12_000)
/// ```
pub fn stage_words(tracked: evolution_pending.Tracked, now: Int) -> String {
  let left = int.to_string(int.max(0, tracked.deadline_ms - now) / 1000)

  // Dispatch on stage_words state.
  case tracked.stage {
    evolution_pending.Submitted -> "sending the request…"
    evolution_pending.Staging(_) -> "staging… (" <> left <> " s left)"
    evolution_pending.Publishing ->
      "committed, publishing… (" <> left <> " s left)"
    evolution_pending.Landed(Some(generation)) ->
      "generation " <> int.to_string(generation) <> " is live"
    evolution_pending.Landed(None) -> "selected"
    evolution_pending.Refused(reason:) -> "the selection failed: " <> reason
    evolution_pending.Vanished -> "the daemon no longer holds this request"
    evolution_pending.TimedOut ->
      "still not finished; the board has been read again"
  }
}

// --- the changes a row offers -----------------------------------------------

/// The buttons, or nothing when the row offers none. An open question replaces
/// the buttons of its own row in the same place.
fn actions(
  page: Page,
  offers: evolving.Offers,
  presses: Presses(message),
) -> Element(message) {
  let offered =
    list.filter(evolving.all(offers), fn(armed) {
      !evolving.asking(page.state, armed)
    })

  // Dispatch on actions state.
  case offered, open_question(page, offers) {
    [], _ | _, Some(_) -> element.none()
    _, None ->
      html.div(
        [attribute.class("evolution-actions")],
        list.map(offered, fn(armed) { action_button(armed, presses) }),
      )
  }
}

/// Action button helper.
fn action_button(
  armed: evolving.Armed,
  presses: Presses(message),
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class(button_class(armed.act)),
      event.on_click(presses.ask(armed)),
    ],
    [html.text(button_label(armed))],
  )
}

/// The closed set of classes a change's button may have.
fn button_class(act: evolving.Act) -> String {
  case act {
    evolving.Approving -> "evolution-approve"
    evolving.Selecting -> "evolution-select"
    evolving.RollingBack -> "evolution-rollback"
    evolving.Revoking -> "evolution-revoke"
  }
}

/// A button names what it will ask for: an approval, a selection as the next
/// generation, a revocation, or an earlier candidate to roll back to.
fn button_label(armed: evolving.Armed) -> String {
  case armed.act {
    evolving.Approving -> evolving.approve_label
    evolving.Revoking -> evolving.revoke_label
    evolving.Selecting ->
      "Select as generation " <> int.to_string(armed.expected_generation + 1)
    evolving.RollingBack ->
      "Roll back to " <> evolution.short_id(armed.candidate_id)
  }
}

/// The open question of this row, when the change it armed is one of the row's
/// offers. A question whose change the board no longer offers is not drawn, and
/// the confirm refuses it too.
fn open_question(
  page: Page,
  offers: evolving.Offers,
) -> Option(evolving.Armed) {
  case page.state.armed {
    Some(armed) ->
      case list.contains(evolving.all(offers), armed) {
        True -> Some(armed)
        False -> None
      }
    None -> None
  }
}

/// Question helper.
fn question(
  page: Page,
  offers: evolving.Offers,
  presses: Presses(message),
) -> List(Element(message)) {
  case open_question(page, offers) {
    None -> []
    Some(armed) -> [ask(armed, presses)]
  }
}

/// The question that replaces the buttons in place: what is being asked, in the
/// ids and the generation the page drew, and the way to confirm or go back.
fn ask(armed: evolving.Armed, presses: Presses(message)) -> Element(message) {
  html.div([attribute.class("evolution-ask"), attribute.role("group")], [
    html.p([attribute.class("evolution-ask-lead"), attribute.role("alert")], [
      html.text(question_words(armed)),
    ]),
    html.p([attribute.class("session-quiet")], [html.text(consequence(armed))]),
    case armed.act {
      evolving.Approving ->
        html.div([attribute.class("share-actions")], [
          confirm_button(
            evolving.approve_label,
            attribute.type_("button"),
            event.on_click(presses.approve),
          ),
          keep_button(presses),
        ])
      evolving.Selecting | evolving.RollingBack | evolving.Revoking ->
        html.form([attribute.class("evolution-ask-form"), presses.submit], [
          reason_field(armed.act),
          html.div([attribute.class("share-actions")], [
            confirm_button(
              confirm_label(armed.act),
              attribute.type_("submit"),
              attribute.none(),
            ),
            keep_button(presses),
          ]),
        ])
    },
  ])
}

/// Confirm button helper.
fn confirm_button(
  label: String,
  kind: attribute.Attribute(message),
  press: attribute.Attribute(message),
) -> Element(message) {
  html.button([kind, attribute.class("share-make"), press], [html.text(label)])
}

/// Keep button helper.
fn keep_button(presses: Presses(message)) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("share-cancel"),
      event.on_click(presses.keep),
    ],
    [html.text(evolving.keep_label)],
  )
}

/// Reason field helper.
fn reason_field(act: evolving.Act) -> Element(message) {
  html.label([attribute.class("evolution-reason")], [
    html.span([attribute.class("session-quiet")], [html.text("Reason")]),
    html.input([
      attribute.type_("text"),
      attribute.name("text"),
      attribute.value(evolving.default_reason(act)),
      attribute.aria_label("Reason"),
      attribute.attribute("maxlength", int.to_string(evolving.reason_limit)),
      attribute.attribute("autocomplete", "off"),
    ]),
  ])
}

/// Confirm label helper.
fn confirm_label(act: evolving.Act) -> String {
  case act {
    evolving.Approving -> evolving.approve_label
    evolving.Selecting -> "Select"
    evolving.RollingBack -> "Roll back"
    evolving.Revoking -> evolving.revoke_label
  }
}

/// The sentence a question opens with. It names the candidate by name and
/// short identity, the evidence an approval or a selection rests on, and the
/// generation a selection replaces, all as the page drew them.
///
/// ## Examples
///
/// ```gleam
/// // evolution_view.question_words(armed)
/// ```
pub fn question_words(armed: evolving.Armed) -> String {
  let target = armed.name <> " " <> evolution.short_id(armed.candidate_id)
  let evidence = evolution.short_id(armed.evidence_id)

  // Dispatch on question_words state.
  case armed.act {
    evolving.Approving ->
      "Approve " <> target <> " on evidence " <> evidence <> "?"
    evolving.Revoking ->
      "Revoke the approval of " <> target <> " (evidence " <> evidence <> ")?"
    evolving.Selecting ->
      "Select "
      <> target
      <> " as generation "
      <> int.to_string(armed.expected_generation + 1)
      <> replacing(armed.expected_generation)
      <> ", on evidence "
      <> evidence
      <> "?"
    evolving.RollingBack ->
      "Select "
      <> target
      <> " again as generation "
      <> int.to_string(armed.expected_generation + 1)
      <> replacing(armed.expected_generation)
      <> ", on evidence "
      <> evidence
      <> "?"
  }
}

fn replacing(generation: Int) -> String {
  case generation {
    0 -> ""
    _ -> ", replacing generation " <> int.to_string(generation)
  }
}

/// What the act does beyond the row, in fixed words.
fn consequence(armed: evolving.Armed) -> String {
  case armed.act {
    evolving.Approving ->
      "An approved candidate can then be selected. Approving a program or a prompt applies to every session its scope names."
    evolving.Revoking ->
      "A revoked candidate cannot be selected until it is approved again."
    evolving.Selecting | evolving.RollingBack ->
      "The running generation is retired first and the new one staged, which can take a minute. A rollback can select the earlier one again."
  }
}

// --- what was decided -------------------------------------------------------

/// The audit journal, newest first. Each entry says when, what was decided, for
/// which candidate, by whom and from where, and the reason given.
fn history(board: evolution.Board) -> Element(message) {
  let shown = list.take(board.history, history_shown)
  let older =
    list.length(board.history) - list.length(shown) + board.omitted_history
  html.section(
    [attribute.class("evolution-section"), attribute.aria_label("History")],
    [
      heading("History"),
      case shown {
        [] -> quiet("Nothing has been decided yet.")
        _ ->
          html.ul(
            [attribute.class("evolution-history")],
            list.map(shown, fn(entry) {
              html.li([attribute.class("evolution-event")], [
                html.text(event_words(entry)),
              ])
            }),
          )
      },
      ..case older {
        0 -> []
        count -> [
          quiet(int.to_string(count) <> " older entries are not shown."),
        ]
      }
    ],
  )
}

/// One journal entry in words: `2026-10-23 14:33 UTC · selected fmt_check as
/// generation 3 · owner · web · "reason"`.
///
/// ## Examples
///
/// ```gleam
/// // evolution_view.event_words(entry)
/// ```
pub fn event_words(entry: evolution.Event) -> String {
  // Dispatch on event_words state.
  let subject = case entry.name {
    "" -> evolution.short_id(entry.candidate_id)
    name -> name <> " " <> evolution.short_id(entry.candidate_id)
  }

  // Dispatch on event_words state.
  let generation = case entry.generation {
    Some(generation) -> " as generation " <> int.to_string(generation)
    None -> ""
  }

  // Dispatch on event_words state.
  let who = case entry.principal, evolution.surface_words(entry.via) {
    "", "" -> ""
    principal, "" -> " · " <> evolution.principal_words(principal)
    "", surface -> " · " <> surface
    principal, surface ->
      " · " <> evolution.principal_words(principal) <> " · " <> surface
  }

  // The reason the person gave, quoted, ends the line.
  let reason = case entry.reason {
    "" -> ""
    reason -> " · \"" <> reason <> "\""
  }

  stamp(entry.at_ms)
  <> " · "
  <> evolution.decision_words(entry.decision)
  <> " "
  <> subject
  <> generation
  <> who
  <> reason
}

// --- the core component -----------------------------------------------------

/// The card for the core component: read-only, because the daemon admits a core
/// upgrade to the native owner alone. It says what the last read found and where
/// upgrades are run.
fn core_card(page: Page, presses: Presses(message)) -> List(Element(message)) {
  case page.core {
    NoCard -> []
    Card(opened:) -> [
      html.section(
        [
          attribute.class("evolution-section"),
          attribute.class("evolution-core"),
          attribute.aria_label("Core"),
        ],
        [
          heading("Core"),
          quiet(core_status_words(opened)),
          quiet(evolution.core_words),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("evolution-read"),
              event.on_click(presses.core),
            ],
            [html.text("Read core status")],
          ),
        ],
      ),
    ]
  }
}

/// What the last `core_status` read found, in words, or that none has been
/// read. A reply that is not the status of a component is drawn as such.
///
/// ## Examples
///
/// ```gleam
/// assert evolution_view.core_status_words(None) == "The core status has not been read."
/// ```
pub fn core_status_words(opened: Option(evolution.Opened)) -> String {
  case opened {
    Some(evolution.Opened(action: "core_status", page: evolution.Whole(value))) ->
      core_fields(value)
    Some(evolution.Opened(action: "core_status", page: evolution.Large(_))) ->
      "The core status is too large to show here."
    _ -> "The core status has not been read."
  }
}

/// Core fields helper.
fn core_fields(value: json.JsonValue) -> String {
  // Dispatch on core_fields state.
  case value {
    json.Object(fields) -> {
      let component = field(fields, "component")
      let version = field(fields, "version")
      let digest = string.slice(field(fields, "digest"), 0, 8)
      let state = field(fields, "state_version")

      // Dispatch on core_fields state.
      case component, version {
        "", "" -> "The core status could not be read."
        _, _ ->
          component
          <> " component · version "
          <> version
          <> " · digest "
          <> digest
          <> " · state version "
          <> state
      }
    }
    _ -> "The core status could not be read."
  }
}

fn field(fields: List(#(String, json.JsonValue)), name: String) -> String {
  case list.key_find(fields, name) {
    Ok(json.String(text)) -> string.replace(text, "\n", " ")
    _ -> ""
  }
}
