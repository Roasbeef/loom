//// The project board screen: what needs the owner in a project, and a way to
//// settle it from the terminal (protocol-change/106).
////
//// The screen is the session picker's sibling. It is an overlay over the
//// conversation, it owns a pure `State`, `update` turns a key into an
//// `Action` for the shell, and `render` draws the state. The shell turns an
//// action into a daemon control job and files the reply back through
//// `observe`, `observed_ticket` or `answer_refused`, so nothing here performs
//// I/O.
////
//// A project has few tickets that need a person and many that do not, so the
//// list shows only the first kind by default. They are grouped by the stage
//// word the daemon sent, most urgent first, and everything else is one line:
//// that nothing else needs the owner, and how many tickets are working or
//// queued. `a` widens the list to every ticket. Enter on a ticket opens its
//// page, which says why the ticket was allowed, shows the worker's question
//// with an answer input, lists the messages the worker was given, and offers
//// the worker's session.
////
//// Two facts about the data decide the design. The board is a poll, and the
//// daemon's `revision` says whether anything changed, so `observe` keeps the
//// board it has when the new one has the same revision, and the shell skips the
//// repaint. And an answer echoes the question's sequence number as the ticket
//// displayed it: the daemon refuses an answer to a question that has since
//// changed, `answer_refused` says so in words, and the screen keeps the
//// person's draft so that the text is not lost.
////
//// All ticket text is external. `session_view/project_board` makes each string
//// safe when it decodes, and this module draws it as text only.
////
//// ## Flow
////
//// `new` → `observe` → `update` → `render`
////
//// 1. `new` opens the screen for a workspace with nothing read yet.
//// 2. `observe` files a board read, `observed_ticket` a ticket read, and
////    `answer_refused` or `answered` the outcome of an answer.
//// 3. `update` dispatches by page: `listing` for the board, `reading` for one
////    ticket, whose keys depend on whether the answer input or the actions
////    have the focus.
//// 4. `render` draws `list_lines` or `ticket_lines` under a frame and ends with
////    `help_line`.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/project_board as board
import session_view/text_hygiene
import tui/theme

/// The most bytes of an answer the input accepts. The daemon takes more; this
/// is the size of a reply a person types into a terminal.
const draft_limit = 4096

/// The width of the age column. The largest real age is a few thousand days.
const age_width = 6

/// The most input messages a ticket page draws, each cut to a few rows.
const inputs_shown = 5

/// Which tickets the list draws.
pub type Scope {
  /// Only tickets that need a person, grouped by stage, and one line for the
  /// rest.
  NeedsYou

  /// Every ticket on the page, grouped by stage.
  Everything
}

/// Where the keyboard goes on a ticket's page.
pub type Focus {
  /// Typing writes the answer to the worker's question.
  Answering

  /// Letters are actions: open the worker's session, close, retry.
  Acting
}

/// The page the screen shows.
pub type Page {
  /// The board.
  Listing

  /// One ticket.
  Reading(
    /// The ticket's id.
    ticket: String,
    /// Where the keyboard goes.
    focus: Focus,
    /// The answer being typed.
    draft: String,
  )
}

/// Everything the screen knows. It holds what the daemon last said and what the
/// person is doing, and nothing about how to ask.
pub type State {
  State(
    /// The workspace the screen was opened for, which names the project.
    workspace: String,
    /// The project's id, once a read has named it.
    project: Option(String),
    /// The board as last read; none until the first read answers.
    board: Option(board.Board),
    /// The open ticket as last read, which may belong to a ticket other than
    /// the open page's until its read answers.
    detail: Option(board.Detail),
    /// Which tickets the list draws.
    scope: Scope,
    /// The highlighted row, an index into `visible`.
    selected: Int,
    /// The page.
    page: Page,
    /// The last refusal or confirmation, in words.
    notice: String,
    /// Whether the shell may read the board now.
    poll: Poll,
  )
}

/// When the board is read next. The time is the terminal's monotonic clock,
/// which can be negative on the BEAM, so "due now" is a case of its own and
/// not a time of zero.
pub type Poll {
  /// Read at the next tick.
  PollDue

  /// Read once the clock reaches this time.
  PollResting(
    /// The monotonic time, in milliseconds, at which the rest ends.
    until_ms: Int,
  )
}

/// What the shell should do after a key.
pub type Action {
  /// Keep the screen with this state.
  Continue(state: State)

  /// Leave the screen.
  Close

  /// Read this ticket, with the page already switched to it.
  Open(state: State, ticket: String)

  /// Send an answer to the ticket's question, echoing its sequence number.
  Send(state: State, ticket: String, seq: Int, text: String)

  /// Close the ticket: the person accepted its work.
  Accept(state: State, ticket: String)

  /// Ask for a new assignment on the ticket.
  Retry(state: State, ticket: String)

  /// Open this worker session.
  Worker(session: String)
}

/// The screen for a workspace, before any read has answered.
///
/// ## Examples
///
/// ```gleam
/// assert project_screen.new("/work/repo").board == None
/// ```
pub fn new(workspace: String) -> State {
  State(
    workspace:,
    project: None,
    board: None,
    detail: None,
    scope: NeedsYou,
    selected: 0,
    page: Listing,
    notice: "",
    poll: PollDue,
  )
}

/// Files a board read. A board with the revision the screen already holds
/// changes nothing, so the shell can compare the two states and skip the
/// repaint; a board with a new revision replaces it and keeps the highlight on
/// the same ticket when that ticket is still there.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.observe(state, decoded_board, now_ms)
/// ```
pub fn observe(state: State, fresh: board.Board, now_ms: Int) -> State {
  let rested =
    State(..state, poll: PollResting(until_ms: now_ms + board.refresh_ms))

  // A board with the revision already held replaces nothing, so the picture
  // stays as it was and the shell does not repaint. A new revision replaces the
  // board and keeps the highlight on the same ticket when it is still there.
  case state.board {
    Some(held) if held.revision == fresh.revision ->
      State(..rested, project: Some(fresh.project))
    Some(_) | None -> {
      let highlighted = option.map(selected_ticket(state), fn(each) { each.id })
      let next =
        State(..rested, project: Some(fresh.project), board: Some(fresh))
      State(..next, selected: reselect(next, highlighted))
    }
  }
}

/// Files a ticket read. It is kept only for the ticket the page is on, so a
/// slow reply for a ticket the person has left changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.observed_ticket(state, decoded_detail)
/// ```
pub fn observed_ticket(state: State, detail: board.Detail) -> State {
  case state.page {
    Reading(ticket:, ..) if ticket == detail.ticket.id ->
      State(..state, detail: Some(detail))
    Reading(..) | Listing -> state
  }
}

/// Records that an answer was accepted: the draft is cleared and the notice
/// says so. The next read shows the ticket as the daemon now has it.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.answered(state)
/// ```
pub fn answered(state: State) -> State {
  case state.page {
    Reading(ticket:, ..) ->
      State(
        ..state,
        page: Reading(ticket:, focus: Acting, draft: ""),
        notice: "Answer queued for the worker.",
        poll: PollDue,
      )
    Listing -> state
  }
}

/// Records a refused answer in words and keeps the draft, so the person can
/// read the new question and send the text again if it still fits. A read is
/// due at once, so the new question is on screen.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.answer_refused(state, "conflict")
/// ```
pub fn answer_refused(state: State, code: String) -> State {
  State(..state, notice: board.answer_refusal_words(code), poll: PollDue)
}

/// Records a failure the screen cannot act on, such as a lost connection.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.failed(state, "the daemon did not answer")
/// ```
pub fn failed(state: State, reason: String) -> State {
  State(..state, notice: text_hygiene.single_line(reason))
}

/// Whether two states draw the same picture. The poll state and nothing else
/// differs between a state and the one `observe` makes from an unchanged
/// board.
///
/// ## Examples
///
/// ```gleam
/// assert project_screen.same_picture(state, state)
/// ```
pub fn same_picture(a: State, b: State) -> Bool {
  State(..a, poll: PollDue) == State(..b, poll: PollDue)
}

/// Whether the shell should read the board now: no rest is pending, or the rest
/// after the last answer has passed.
///
/// ## Examples
///
/// ```gleam
/// assert project_screen.poll_due(project_screen.new("/w"), 0)
/// ```
pub fn poll_due(state: State, now_ms: Int) -> Bool {
  case state.poll {
    PollDue -> True
    PollResting(until_ms:) -> now_ms >= until_ms
  }
}

/// Holds the poll until `until_ms`, as after a failed read.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.rest(state, now_ms + 5000)
/// ```
pub fn rest(state: State, until_ms: Int) -> State {
  State(..state, poll: PollResting(until_ms:))
}

/// The tickets the list draws, in the order it draws them: the board's
/// tickets in reading order, narrowed by the scope.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.visible(state)
/// ```
pub fn visible(state: State) -> List(board.Ticket) {
  case state.board {
    None -> []
    Some(held) ->
      case state.scope {
        Everything -> board.ordered(held.tickets)
        NeedsYou -> board.needing(held)
      }
  }
}

/// The highlighted ticket, if the list has one.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.selected_ticket(state)
/// ```
pub fn selected_ticket(state: State) -> Option(board.Ticket) {
  visible(state)
  |> list.drop(state.selected)
  |> list.first
  |> option.from_result
}

/// The id of the ticket the page is on, if it is on one.
///
/// ## Examples
///
/// ```gleam
/// assert project_screen.open_ticket(project_screen.new("/w")) == None
/// ```
pub fn open_ticket(state: State) -> Option(String) {
  case state.page {
    Reading(ticket:, ..) -> Some(ticket)
    Listing -> None
  }
}

/// Handles one key.
///
/// ## Examples
///
/// ```gleam
/// assert project_screen.update(keys.Escape, project_screen.new("/w"))
///   == project_screen.Close
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  case state.page {
    Listing -> listing(key, state)
    Reading(ticket:, focus:, draft:) ->
      reading(key, state, ticket, focus, draft)
  }
}

/// Handles pasted text. It goes into the answer input when that has the
/// keyboard, and is ignored everywhere else, so that a paste cannot be read as
/// a list key.
///
/// ## Examples
///
/// ```gleam
/// assert project_screen.update_pasted("a", project_screen.new("/w"))
///   == project_screen.Continue(project_screen.new("/w"))
/// ```
pub fn update_pasted(pasted: String, state: State) -> Action {
  case state.page {
    Reading(ticket:, focus: Answering, draft:) ->
      answering(keys.Char(pasted), state, ticket, draft)
    Reading(focus: Acting, ..) | Listing -> Continue(state)
  }
}

// --- keys --------------------------------------------------------------------

/// Keys on the board: move, widen, open, leave.
fn listing(key: keys.Key, state: State) -> Action {
  let last = int.max(0, list.length(visible(state)) - 1)

  // The movement keys change only the highlight, and Enter and `a` change the
  // page or the scope; nothing here asks the daemon for anything but Enter.
  case key {
    keys.Escape -> Close
    keys.Up ->
      Continue(State(..state, selected: int.max(0, state.selected - 1)))
    keys.Down ->
      Continue(State(..state, selected: int.min(last, state.selected + 1)))
    keys.Home -> Continue(State(..state, selected: 0))
    keys.End -> Continue(State(..state, selected: last))
    keys.Enter -> open_selected(state)

    // Widening or narrowing the list moves the rows under the cursor, so the
    // highlight goes back to the top rather than pointing at a stranger.
    keys.Char("a") ->
      Continue(State(..state, scope: other_scope(state.scope), selected: 0))
    keys.Char("r") -> Continue(State(..state, poll: PollDue))
    _ -> Continue(state)
  }
}

/// Opens the highlighted ticket's page. The keyboard starts in the answer
/// input when the ticket has an open question and on the actions otherwise.
fn open_selected(state: State) -> Action {
  // An empty list has nothing to open, and Enter on it does nothing.
  case selected_ticket(state) {
    None -> Continue(state)
    Some(found) -> {
      // Typing goes to the answer only when there is a question to answer, so
      // a letter pressed on any other ticket is an action and not an answer.
      let focus = case found.question {
        Some(_) -> Answering
        None -> Acting
      }

      let page = Reading(ticket: found.id, focus:, draft: "")
      Open(State(..state, page:, detail: None, notice: ""), found.id)
    }
  }
}

/// Keys on a ticket's page.
fn reading(
  key: keys.Key,
  state: State,
  ticket: String,
  focus: Focus,
  draft: String,
) -> Action {
  case key, focus {
    keys.Tab, Answering ->
      Continue(State(..state, page: Reading(ticket:, focus: Acting, draft:)))
    keys.Tab, Acting ->
      Continue(State(..state, page: Reading(ticket:, focus: Answering, draft:)))
    keys.Escape, Answering if draft != "" ->
      Continue(State(..state, page: Reading(ticket:, focus:, draft: "")))
    keys.Escape, _ ->
      Continue(State(..state, page: Listing, detail: None, notice: ""))
    _, Answering -> answering(key, state, ticket, draft)
    _, Acting -> acting(key, state, ticket)
  }
}

/// Keys while the answer input has the keyboard.
fn answering(
  key: keys.Key,
  state: State,
  ticket: String,
  draft: String,
) -> Action {
  // Printable keys edit the draft, and Enter sends it. Everything else is
  // ignored, so no key can be read as a command while an answer is typed.
  case key {
    keys.Enter -> send(state, ticket, draft)
    keys.Backspace -> drafting(state, ticket, string.drop_end(draft, 1))
    keys.Ctrl("u") -> drafting(state, ticket, "")
    keys.Char(character) -> {
      let next = draft <> text_hygiene.single_line(character)

      // A draft past the limit stops growing rather than being cut, so what
      // the person sees is what would be sent.
      case string.byte_size(next) <= draft_limit {
        True -> drafting(state, ticket, next)
        False -> Continue(state)
      }
    }
    _ -> Continue(state)
  }
}

/// The screen with the answer input holding `draft`.
fn drafting(state: State, ticket: String, draft: String) -> Action {
  Continue(State(..state, page: Reading(ticket:, focus: Answering, draft:)))
}

/// Sends the draft as the answer to the ticket's open question. An empty
/// draft, or a ticket with no open question, sends nothing.
fn send(state: State, ticket: String, draft: String) -> Action {
  case string.trim(draft), current(state, ticket) {
    "", _ | _, None -> Continue(state)
    text, Some(found) ->
      case found.question {
        Some(question) -> Send(state, ticket, question.seq, text)
        None ->
          Continue(State(..state, notice: "This ticket has no open question."))
      }
  }
}

/// Keys while the actions have the keyboard.
fn acting(key: keys.Key, state: State, ticket: String) -> Action {
  case key, current(state, ticket) {
    keys.Char("o"), Some(found) | keys.Enter, Some(found) ->
      case found.session {
        Some(session) -> Worker(session)
        None ->
          Continue(State(..state, notice: "No worker session is bound yet."))
      }
    keys.Char("c"), Some(found) ->
      case board.offers(found, board.CanClose) {
        True -> Accept(state, ticket)
        False ->
          Continue(State(..state, notice: "That ticket cannot be closed now."))
      }
    keys.Char("t"), Some(found) ->
      case board.offers(found, board.CanRetry) {
        True -> Retry(state, ticket)
        False ->
          Continue(State(..state, notice: "That ticket cannot be retried now."))
      }
    _, _ -> Continue(state)
  }
}

/// The ticket the page is on, from the ticket read when it has answered and
/// from the board before that.
fn current(state: State, ticket: String) -> Option(board.Ticket) {
  case state.detail {
    Some(detail) if detail.ticket.id == ticket -> Some(detail.ticket)
    Some(_) | None ->
      case state.board {
        Some(held) ->
          list.find(held.tickets, fn(each) { each.id == ticket })
          |> option.from_result
        None -> None
      }
  }
}

fn other_scope(scope: Scope) -> Scope {
  case scope {
    NeedsYou -> Everything
    Everything -> NeedsYou
  }
}

/// The index of the ticket with this id in the visible rows, or the nearest
/// row that still exists.
fn reselect(state: State, highlighted: Option(String)) -> Int {
  let rows = visible(state)

  // The highlighted id is looked up in the new rows; a ticket that has left
  // the board leaves the highlight at the nearest row that remains.
  let found = case highlighted {
    Some(id) ->
      list.index_map(rows, fn(each, index) { #(each.id, index) })
      |> list.key_find(id)
    None -> Error(Nil)
  }

  result.lazy_unwrap(found, fn() {
    int.min(state.selected, int.max(0, list.length(rows) - 1))
  })
}

// --- drawing -----------------------------------------------------------------

/// Draws the screen over the conversation.
///
/// ## Examples
///
/// ```gleam
/// // project_screen.render(buf, screen, state, now_ms)
/// ```
pub fn render(
  buf: buffer.Buffer,
  screen: Rect,
  state: State,
  now_ms: Int,
) -> buffer.Buffer {
  let width = int.max(1, int.min(100, screen.size.width - 4))
  let area =
    geometry.centered_rect(width, int.max(1, screen.size.height - 4), screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [span.span_styled(title(state), theme.overlay_signal())],
      block.Top,
    )
    |> block.with_padding(1, 0, 1, 1)
  let inside = block.inner(area, frame)
  let body_height = int.max(0, inside.size.height - 2)
  let body =
    geometry.rect_new(
      inside.position.x,
      inside.position.y,
      inside.size.width,
      body_height,
    )
  let footer =
    geometry.rect_new(
      inside.position.x,
      inside.position.y + body_height,
      inside.size.width,
      2,
    )
  let lines = body_lines(state, inside.size.width, now_ms)

  buf
  |> buffer.clear(screen)
  |> buffer.set_style(area, theme.overlay_plain())
  |> block.render(area, frame)
  |> paragraph.render_styled(body, window(lines, body_height))
  |> paragraph.render_styled(footer, [
    span.line_new([]),
    help_line(state, inside.size.width),
  ])
}

/// A drawn line, tagged when it is the highlighted row so that the window can
/// keep the highlight on screen.
type Drawn {
  Drawn(line: span.Line, highlighted: Marked)
}

/// Whether a drawn line is the highlighted row.
type Marked {
  Marked
  Unmarked
}

/// The title, which says which project and whether it is a ticket.
fn title(state: State) -> String {
  case state.page {
    Listing -> " PROJECT · Esc back "
    Reading(..) -> " PROJECT · ticket · Esc back "
  }
}

/// The lines of the current page.
fn body_lines(state: State, width: Int, now_ms: Int) -> List(Drawn) {
  case state.page {
    Listing -> list_lines(state, width, now_ms)
    Reading(ticket:, focus:, draft:) ->
      ticket_lines(state, ticket, focus, draft, width, now_ms)
  }
}

/// The board: a notice if there is one, then the groups, then one line for
/// everything that needs nobody.
fn list_lines(state: State, width: Int, now_ms: Int) -> List(Drawn) {
  let notice = notice_lines(state, width)

  // Before the first read answers there is nothing to count, so the screen
  // says it is reading and not that the project is empty.
  case state.board {
    None ->
      list.append(notice, [
        plain("Reading the project...", theme.overlay_quiet()),
      ])
    Some(held) -> {
      let rows = groups_lines(state, width, now_ms)
      let health = [
        plain("", theme.overlay_plain()),
        plain(
          text.truncate(board.health_words(held), width, "…"),
          theme.overlay_quiet(),
        ),
      ]

      list.flatten([
        notice,
        rows,
        health,
        unreadable_lines(held, width),
        would_lines(held, width),
      ])
    }
  }
}

/// What `observe` rules recorded as work they would have done, under one
/// heading, so the owner can judge a rule before it is allowed to act. The
/// address of each message is drawn as text, like a pull request's.
fn would_lines(held: board.Board, width: Int) -> List(Drawn) {
  case held.would {
    [] -> []
    rows -> [
      plain("", theme.overlay_plain()),
      plain(
        "WOULD HAVE DONE (" <> int.to_string(list.length(rows)) <> ")",
        theme.overlay_quiet(),
      ),
      ..list.flat_map(rows, fn(each) {
        [
          plain(
            text.truncate(board.would_words(each), width, "…"),
            theme.overlay_plain(),
          ),
          ..case each.link {
            Some(link) -> [
              plain(
                text.truncate("  " <> link, width, "…"),
                theme.overlay_quiet(),
              ),
            ]
            None -> []
          }
        ]
      })
    ]
  }
}

/// The visible tickets under a heading for each stage word.
fn groups_lines(state: State, width: Int, now_ms: Int) -> List(Drawn) {
  let rows = visible(state)
  let indexed = list.index_map(rows, fn(each, index) { #(each, index) })

  board.groups(rows)
  |> list.fold(#([], 0), fn(drawn, group) {
    let #(lines, offset) = drawn
    let count = list.length(group.tickets)
    let members = list.take(list.drop(indexed, offset), count)
    let heading = Drawn(heading_line(group, width), Unmarked)
    let each =
      list.map(members, fn(member) {
        ticket_row(member.0, marked(member.1, state.selected), width, now_ms)
      })

    #(list.append(lines, [heading, ..each]), offset + count)
  })
  |> fn(done) { done.0 }
}

/// A stage heading: the stage word and how many tickets are under it.
fn heading_line(group: board.Group, width: Int) -> span.Line {
  // Only a stage that needs the person is drawn in the signal style, so the
  // quiet stages of the wide list recede.
  let look = case group.needs {
    board.NeedsPerson -> theme.overlay_signal()
    board.NeedsNobody -> theme.overlay_quiet()
  }

  span.line_new([
    span.span_styled(
      text.truncate(
        string.uppercase(group.word)
          <> " ("
          <> int.to_string(list.length(group.tickets))
          <> ")",
        width,
        "…",
      ),
      look,
    ),
  ])
}

/// Whether the row at `index` is the highlighted one.
fn marked(index: Int, selected: Int) -> Marked {
  case index == selected {
    True -> Marked
    False -> Unmarked
  }
}

/// One ticket: a marker, its title, and its age.
fn ticket_row(
  ticket: board.Ticket,
  mark: Marked,
  width: Int,
  now_ms: Int,
) -> Drawn {
  let age = text.pad_left(board.age_words(ticket.opened_ms, now_ms), age_width)
  let room = int.max(1, width - 2 - age_width - 1)
  let title =
    text.pad_right(text.truncate(board.title_words(ticket), room, "…"), room)

  // The highlighted row carries its mark and a raised background, and the
  // same text in the same columns as every other row.
  case mark {
    Marked ->
      Drawn(
        span.line_new([
          span.span_styled(
            "▸ ",
            style.new(theme.signal, theme.raised, style.bold()),
          ),
          span.span_styled(
            title <> " ",
            style.new(theme.paper, theme.raised, style.bold()),
          ),
          span.span_styled(
            age,
            style.new(theme.quiet, theme.raised, style.none()),
          ),
        ]),
        Marked,
      )
    Unmarked ->
      Drawn(
        span.line_new([
          span.span_styled("  ", theme.overlay_plain()),
          span.span_styled(title <> " ", theme.overlay_plain()),
          span.span_styled(age, theme.overlay_quiet()),
        ]),
        Unmarked,
      )
  }
}

/// A line saying how many rows the daemon sent that this client could not
/// address, when there were any.
fn unreadable_lines(held: board.Board, width: Int) -> List(Drawn) {
  case held.unreadable {
    0 -> []
    count -> [
      plain(
        text.truncate(
          int.to_string(count) <> " tickets could not be read by this client.",
          width,
          "…",
        ),
        theme.overlay_quiet(),
      ),
    ]
  }
}

/// A ticket's page.
fn ticket_lines(
  state: State,
  ticket: String,
  focus: Focus,
  draft: String,
  width: Int,
  now_ms: Int,
) -> List(Drawn) {
  case current(state, ticket) {
    None ->
      list.append(notice_lines(state, width), [
        plain("This ticket is not on the board.", theme.overlay_quiet()),
      ])
    Some(found) ->
      list.flatten([
        notice_lines(state, width),
        head_lines(found, width, now_ms),
        question_lines(found, focus, draft, width),
        worker_lines(found, state, width),
        input_lines(state, ticket, width),
      ])
  }
}

/// The title, the stage, the age, and why the ticket was allowed.
fn head_lines(ticket: board.Ticket, width: Int, now_ms: Int) -> List(Drawn) {
  let facts =
    board.stage_word(ticket.stage)
    <> " · "
    <> board.opened_words(ticket.opened_ms, now_ms)
    <> " · "
    <> ticket.id

  list.flatten([
    [
      plain(
        text.truncate(board.title_words(ticket), width, "…"),
        theme.overlay_current(),
      ),
    ],
    [plain(text.truncate(facts, width, "…"), theme.overlay_quiet())],
    wrapped(board.mandate_words(ticket.mandate), theme.overlay_plain(), width),
    [plain("", theme.overlay_plain())],
  ])
}

/// The worker's question and the answer input. A ticket with no open question
/// says so and draws no input.
fn question_lines(
  ticket: board.Ticket,
  focus: Focus,
  draft: String,
  width: Int,
) -> List(Drawn) {
  // The answer input exists only for a ticket with an open question, because
  // the daemon refuses an answer that echoes no question's sequence number.
  case ticket.question {
    None -> [
      plain("No open question.", theme.overlay_quiet()),
      plain("", theme.overlay_plain()),
    ]
    Some(question) -> {
      // The cursor shows where typing goes, and is absent while the keyboard
      // is on the actions.
      let cursor = case focus {
        Answering -> "▏"
        Acting -> ""
      }

      // Options are shown as a hint; the answer is still free text.
      let options = case question.options {
        [] -> []
        found ->
          wrapped(
            "Options: " <> string.join(found, " · "),
            theme.overlay_quiet(),
            width,
          )
      }

      list.flatten([
        [
          plain(
            "QUESTION " <> int.to_string(question.seq),
            theme.overlay_signal(),
          ),
        ],
        wrapped(question.text, theme.overlay_plain(), width),
        options,
        wrapped("Answer: " <> draft <> cursor, theme.overlay_current(), width),
        [plain("", theme.overlay_plain())],
      ])
    }
  }
}

/// The worker's session, and the actions that apply to the ticket.
fn worker_lines(ticket: board.Ticket, state: State, width: Int) -> List(Drawn) {
  // The action is offered only when there is a session to open.
  let session = case ticket.session {
    Some(id) -> "Worker session " <> id <> " · o opens it"
    None -> "No worker session is bound yet."
  }

  // The pull request line appears once the host has opened one.
  let pull_request = case ticket.pull_request {
    Some(address) -> [
      plain(
        text.truncate("Pull request " <> address, width, "…"),
        theme.overlay_quiet(),
      ),
    ]
    None -> []
  }

  // The host's reason for a failed attempt, in its words, when the worker
  // never reported.
  let failure = case ticket.failure {
    Some(why) -> [
      plain(
        text.truncate("Failed: " <> why, width, "…"),
        theme.overlay_signal(),
      ),
    ]
    None -> []
  }

  // Assignments come from the ticket read, and only a read for this ticket
  // counts; a read for a ticket the person left is not drawn here.
  let assignments = case state.detail {
    Some(detail) if detail.ticket.id == ticket.id ->
      assignment_lines(detail, width)
    Some(_) | None -> []
  }

  list.flatten([
    [plain(text.truncate(session, width, "…"), theme.overlay_plain())],
    failure,
    pull_request,
    assignments,
    [plain("", theme.overlay_plain())],
  ])
}

/// One line for the ticket's assignments, newest first.
fn assignment_lines(detail: board.Detail, width: Int) -> List(Drawn) {
  case detail.assignments {
    [] -> []
    found -> [
      plain(
        text.truncate(
          "Assignments: "
            <> string.join(
            list.map(found, fn(each) {
              "#" <> int.to_string(each.seq) <> " " <> each.status
            }),
            ", ",
          ),
          width,
          "…",
        ),
        theme.overlay_quiet(),
      ),
    ]
  }
}

/// The messages the worker was given, newest last, each cut to two rows.
fn input_lines(state: State, ticket: String, width: Int) -> List(Drawn) {
  case state.detail {
    Some(detail) if detail.ticket.id == ticket ->
      case detail.inputs {
        [] -> []
        inputs -> {
          let shown =
            list.drop(inputs, int.max(0, list.length(inputs) - inputs_shown))

          [
            plain("MESSAGES", theme.overlay_signal()),
            ..list.flat_map(shown, fn(each) { input_rows(each, width) })
          ]
        }
      }
    Some(_) | None -> []
  }
}

/// One message: who sent it and where it stands, then its text.
fn input_rows(input: board.Input, width: Int) -> List(Drawn) {
  let who =
    option.unwrap(input.actor, "someone")
    <> " via "
    <> option.unwrap(input.source, "a source")
    <> " · "
    <> board.delivery_words(input.delivery)

  // A message whose text the ledger does not hold says so, because an empty
  // line would read as an empty message.
  let body = case input.text {
    Some(found) ->
      clipped(wrapped(indented(found), theme.overlay_plain(), width))
    None -> [plain("  (the text is not in the ledger)", theme.overlay_quiet())]
  }

  [plain(text.truncate(who, width, "…"), theme.overlay_quiet()), ..body]
}

/// The most lines of one message the page shows.
const message_lines = 2

/// The first lines of a message, and a line that says there is more when it was
/// cut. A message cut at its line limit with nothing after it reads as though
/// the sentence ended there.
fn clipped(lines: List(Drawn)) -> List(Drawn) {
  case list.length(lines) > message_lines {
    True ->
      list.append(list.take(lines, message_lines), [
        plain("  …", theme.overlay_quiet()),
      ])
    False -> lines
  }
}

/// Text with two cells of indent on each of its lines.
fn indented(words: String) -> String {
  text_hygiene.multiline(words)
  |> string.split("\n")
  |> list.map(fn(line) { "  " <> line })
  |> string.join("\n")
}

/// The notice, when there is one.
fn notice_lines(state: State, width: Int) -> List(Drawn) {
  case state.notice {
    "" -> []
    words ->
      list.append(wrapped(words, theme.overlay_signal(), width), [
        plain("", theme.overlay_plain()),
      ])
  }
}

/// The key hints for the page.
fn help_line(state: State, width: Int) -> span.Line {
  // The hints are those of the page and of where the keyboard is, so the
  // person is never told a key that would do nothing.
  let words = case state.page {
    Listing ->
      "↑/↓ select · Enter open · a "
      <> case state.scope {
        NeedsYou -> "show all"
        Everything -> "needs you only"
      }
      <> " · r refresh · Esc back"
    Reading(focus: Answering, ..) ->
      "type an answer · Enter send · Tab actions · Esc clear or back"
    Reading(focus: Acting, ..) ->
      "o open worker · c close · t retry · Tab answer · Esc back"
  }

  span.line_new([
    span.span_styled(text.truncate(words, width, "…"), theme.overlay_signal()),
  ])
}

/// The lines that fit, with the highlighted row kept on screen: the window
/// starts at the first line when the highlight is in it, and otherwise ends at
/// the highlight.
fn window(lines: List(Drawn), height: Int) -> List(span.Line) {
  let marked =
    list.index_map(lines, fn(each, index) { #(each.highlighted, index) })
    |> list.find(fn(pair) { pair.0 == Marked })

  // The window scrolls only when the highlighted row would fall below it.
  let start = case marked {
    Ok(#(_, index)) -> int.max(0, index - height + 1)
    Error(Nil) -> 0
  }

  lines
  |> list.drop(start)
  |> list.take(height)
  |> list.map(fn(each) { each.line })
}

/// One unmarked line in one style, cut to the width by the caller.
fn plain(words: String, appearance: style.Style) -> Drawn {
  Drawn(span.line_new([span.span_styled(words, appearance)]), Unmarked)
}

/// Text wrapped to the width, one drawn line per row. The words are made safe
/// again here, because a notice is built from the daemon's code.
fn wrapped(words: String, appearance: style.Style, width: Int) -> List(Drawn) {
  text_hygiene.multiline(words)
  |> string.split("\n")
  |> list.map(fn(line) { span.line_new([span.span_styled(line, appearance)]) })
  |> span.text_new
  |> span.wrap(int.max(1, width))
  |> fn(done) { done.lines }
  |> list.map(fn(line) { Drawn(line, Unmarked) })
}
