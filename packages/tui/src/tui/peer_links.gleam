//// Owner-controlled peer links for exact session and strand pairs.
////
//// The overlay keeps inspection and draft coordinates separate from the
//// attached conversation. A grant is sent only after the operator reviews
//// its direction and wake permission; each control request remains one-way.

import core/json
import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/agents
import tui/daemon/protocol.{
  type PeerWake, type Session, BusyOnly, MayWake, Resident,
}
import tui/text_hygiene
import tui/theme

/// One peer grant and its exact direction.
pub type Grant {
  Grant(
    /// Session that owns the outgoing permission.
    source_session: String,
    /// Strand that owns the outgoing permission.
    source_strand: String,
    /// Session whose strand receives messages.
    target_session: String,
    /// Exact strand that receives messages.
    target_strand: String,
    /// Recipient permission to start an idle strand.
    wake: Option(PeerWake),
    /// Whether the peer endpoint was available in the last inspection.
    availability: Availability,
  )
}

/// Availability captured with an inspection, never a promise of future residency.
pub type Availability {
  /// The recipient session was resident when inspected.
  Available

  /// The recipient was saved, missing, or unavailable when inspected.
  Unavailable(reason: String)
}

/// Both directions attached to one selected resident session and strand.
pub type Inspection {
  Inspection(
    /// Outgoing grants from the inspected source strand.
    outgoing: List(Grant),
    /// Incoming grants to the inspected source strand.
    incoming: List(Grant),
  )
}

/// One bounded response page and its opaque continuation, when present.
pub type InspectionPage {
  InspectionPage(
    /// Grants decoded from this daemon response.
    inspection: Inspection,
    /// Cursor to fetch the next page.
    next: Option(String),
  )
}

/// The overlay's current interaction stage.
pub type Prompt {
  /// Inspect and revoke grants or begin a new directional grant.
  Browsing

  /// Choose a resident target session from authorized catalogue metadata.
  ChoosingSession

  /// Enter the exact target strand name without changing the composer draft.
  EditingTargetStrand

  /// Review the direction and wake permission before one grant is sent.
  Confirming(proposal: Proposal)
}

/// A grant proposal waiting for explicit confirmation.
pub type Proposal {
  Proposal(
    /// Session that will own the outgoing permission.
    source_session: String,
    /// Strand that will own the outgoing permission.
    source_strand: String,
    /// Resident session that will receive messages.
    target_session: String,
    /// Exact recipient strand.
    target_strand: String,
    /// The explicit wake choice shown before sending.
    wake: PeerWake,
  )
}

/// Modal state owned by the terminal until close or an explicit action.
pub type State {
  State(
    /// Session whose active strand opened this workspace.
    source_session: String,
    /// Exact source strand selected when the workspace opened.
    source_strand: String,
    /// The last catalogue page received from the daemon.
    sessions: List(Session),
    /// Catalogue revision that fences subsequent session pages.
    session_revision: Option(Int),
    /// Continuation for the authorized target-session catalogue.
    session_cursor: Option(String),
    /// Current authorized inspection, absent until its first reply.
    inspection: Option(Inspection),
    /// Next daemon page to append to the current inspection.
    next_cursor: Option(String),
    /// Visible grant index across outgoing rows followed by incoming rows.
    selected_grant: Int,
    /// Highlighted target session while choosing a new link.
    selected_session: Int,
    /// Local draft for the target strand; never borrows the composer buffer.
    target_strand: String,
    /// Restrictive default, changed only by an explicit operator key.
    wake: PeerWake,
    /// Focused form step.
    prompt: Prompt,
    /// Last action result or actionable refusal shown in the overlay.
    notice: String,
    /// Mutation acknowledgement retained across the following inspection.
    operation_result: Option(String),
    /// Agent workspace to resume after this modal, with its cursor intact.
    return_to: Option(agents.Inspector),
  )
}

/// One action produced by keyboard navigation.
pub type Action {
  /// Keep the modal open with updated local state.
  Continue(state: State)

  /// Inspect grants for the selected source coordinates.
  Inspect(session: String, strand: String)

  /// Fetches the next bounded grant page.
  NextPage(cursor: String)

  /// Fetches another authorized target-session catalogue page.
  NextSessions(cursor: String, revision: Int)

  /// Create exactly one directional grant.
  Link(proposal: Proposal)

  /// Revoke exactly one selected direction.
  Unlink(grant: Grant)

  /// Close the modal without changing the conversation or composer.
  Close
}

/// Opens peer management for the currently attached exact strand.
///
/// ## Examples
///
/// ```gleam
/// let state = peer_links.new("session-1", "main")
/// ```
pub fn new(source_session: String, source_strand: String) -> State {
  State(
    source_session:,
    source_strand:,
    sessions: [],
    session_revision: None,
    session_cursor: None,
    inspection: None,
    next_cursor: None,
    selected_grant: 0,
    selected_session: 0,
    target_strand: "",
    wake: BusyOnly,
    prompt: Browsing,
    notice: "loading peer grants",
    operation_result: None,
    return_to: None,
  )
}

/// Opens peer management from a selected agent row and returns to that view.
///
/// ## Examples
///
/// ```gleam
/// let state = peer_links.from_agent("session-1", inspector)
/// ```
pub fn from_agent(
  source_session: String,
  inspector: agents.Inspector,
) -> State {
  State(..new(source_session, inspector.selected), return_to: Some(inspector))
}

/// Replaces catalogue and grant observations after a successful control read.
///
/// ## Examples
///
/// ```gleam
/// let refreshed = peer_links.loaded(state, sessions, inspection)
/// ```
pub fn loaded(
  state: State,
  sessions: List(Session),
  inspection: Inspection,
  next_cursor: Option(String),
) -> State {
  let notice = case next_cursor {
    Some(_) -> "more grants available · press n to continue"
    None -> "peer inspection current · saved targets stay closed"
  }
  State(
    ..state,
    sessions:,
    inspection: Some(inspection),
    next_cursor:,
    selected_grant: int.min(state.selected_grant, last_grant(inspection)),
    notice:,
  )
}

/// Records the first authorized catalogue page without opening saved sessions.
///
/// ## Examples
///
/// ```gleam
/// let state = peer_links.catalogue(state, page)
/// ```
pub fn catalogue(state: State, page: protocol.Page) -> State {
  State(
    ..state,
    sessions: page.sessions,
    session_revision: Some(page.revision),
    session_cursor: page.after,
  )
}

/// Appends another page under the revision selected by the first page.
///
/// ## Examples
///
/// ```gleam
/// let state = peer_links.append_sessions(state, page)
/// ```
pub fn append_sessions(state: State, page: protocol.Page) -> State {
  State(
    ..state,
    sessions: list.append(state.sessions, page.sessions),
    session_cursor: page.after,
    selected_session: list.length(state.sessions),
    notice: case page.after {
      Some(_) -> "more target sessions available · press n to continue"
      None -> "target session catalogue complete"
    },
  )
}

/// Appends one fresh page, replacing duplicate exact coordinates.
///
/// A grant can move across a cursor boundary while the operator pages. Merge
/// by its four coordinates so a repeated row replaces the older observation.
///
/// ## Examples
///
/// ```gleam
/// let state = peer_links.append_page(state, page)
/// ```
pub fn append_page(state: State, page: InspectionPage) -> State {
  let merged = case state.inspection {
    None -> page.inspection
    Some(previous) ->
      Inspection(
        outgoing: merge_grants(previous.outgoing, page.inspection.outgoing),
        incoming: merge_grants(previous.incoming, page.inspection.incoming),
      )
  }
  State(
    ..state,
    inspection: Some(merged),
    next_cursor: page.next,
    selected_grant: int.min(state.selected_grant, last_grant(merged)),
    notice: case page.next {
      Some(_) -> "more grants available · press n to continue"
      None -> "peer inspection complete"
    },
  )
}

/// Keeps an inspection or mutation failure visible for operator action.
///
/// ## Examples
///
/// ```gleam
/// let failed = peer_links.failed(state, "stale epoch")
/// ```
pub fn failed(state: State, reason: String) -> State {
  State(..state, notice: "peer request refused: " <> reason)
}

/// Records an acknowledgement verbatim enough to preserve partial results.
///
/// ## Examples
///
/// ```gleam
/// let updated = peer_links.completed(state, document)
/// ```
pub fn completed(state: State, document: json.JsonValue) -> State {
  let result = case document {
    json.Null -> "peer link updated"
    _ -> "server result: " <> text_hygiene.single_line(json.to_string(document))
  }
  State(
    ..state,
    prompt: Browsing,
    operation_result: Some(result),
    notice: "refreshing peer grants",
  )
}

/// Applies one terminal key while this modal owns keyboard focus.
///
/// ## Examples
///
/// ```gleam
/// let action = peer_links.update(keys.Char("l"), state)
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  case state.prompt {
    Browsing -> update_browsing(key, state)
    ChoosingSession -> update_session_choice(key, state)
    EditingTargetStrand -> update_target_strand(key, state)
    Confirming(proposal) -> update_confirmation(key, state, proposal)
  }
}

fn update_browsing(key: keys.Key, state: State) -> Action {
  let grants = grants(state.inspection)
  case key {
    keys.Escape -> Close
    keys.Char("l") -> Continue(State(..state, prompt: ChoosingSession))
    keys.Char("r") -> Inspect(state.source_session, state.source_strand)
    keys.Char("n") ->
      case state.next_cursor {
        Some(cursor) -> NextPage(cursor)
        None -> Continue(State(..state, notice: "no more peer pages"))
      }
    keys.Up ->
      Continue(
        State(..state, selected_grant: wrap_up(state.selected_grant, grants)),
      )
    keys.Down ->
      Continue(
        State(..state, selected_grant: wrap_down(state.selected_grant, grants)),
      )
    keys.Char("d") ->
      case item_at(grants, state.selected_grant) {
        Ok(grant) -> Unlink(grant)
        Error(Nil) -> Continue(state)
      }
    keys.Char("v") -> reverse_proposal(state, grants)
    keys.Enter -> Continue(state)
    keys.PageUp | keys.PageDown -> Continue(state)
    keys.Backspace
    | keys.Left
    | keys.Right
    | keys.Delete
    | keys.Tab
    | keys.BackTab
    | keys.Home
    | keys.End
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Char(_)
    | keys.Unknown(_) -> Continue(state)
  }
}

fn update_session_choice(key: keys.Key, state: State) -> Action {
  case key {
    keys.Escape -> Continue(State(..state, prompt: Browsing))
    keys.Char("n") ->
      case state.session_cursor, state.session_revision {
        Some(cursor), Some(revision) -> NextSessions(cursor, revision)
        _, _ -> Continue(State(..state, notice: "no more target sessions"))
      }
    keys.Up ->
      Continue(
        State(
          ..state,
          selected_session: wrap_up(state.selected_session, state.sessions),
        ),
      )
    keys.Down ->
      Continue(
        State(
          ..state,
          selected_session: wrap_down(state.selected_session, state.sessions),
        ),
      )
    keys.Enter ->
      case item_at(state.sessions, state.selected_session) {
        Ok(row) ->
          case is_resident(row) {
            True ->
              Continue(
                State(..state, prompt: EditingTargetStrand, target_strand: ""),
              )
            False ->
              Continue(
                State(
                  ..state,
                  notice: "saved session cannot receive links; open it explicitly first",
                ),
              )
          }
        Error(Nil) ->
          Continue(
            State(..state, notice: "no resident target session is available"),
          )
      }
    keys.Backspace
    | keys.Left
    | keys.Right
    | keys.Delete
    | keys.Tab
    | keys.BackTab
    | keys.PageUp
    | keys.PageDown
    | keys.Home
    | keys.End
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Char(_)
    | keys.Unknown(_) -> Continue(state)
  }
}

fn update_target_strand(key: keys.Key, state: State) -> Action {
  case key {
    keys.Escape -> Continue(State(..state, prompt: ChoosingSession))
    keys.Enter ->
      case string.byte_size(state.target_strand) > 0 {
        True -> Continue(State(..state, prompt: Confirming(proposal(state))))
        False ->
          Continue(State(..state, notice: "enter an exact target strand name"))
      }
    keys.Backspace ->
      Continue(
        State(..state, target_strand: drop_last_grapheme(state.target_strand)),
      )
    keys.Char(character) ->
      case string.byte_size(state.target_strand <> character) <= 128 {
        True ->
          Continue(
            State(..state, target_strand: state.target_strand <> character),
          )
        False ->
          Continue(State(..state, notice: "target strand exceeds 128 bytes"))
      }
    keys.Up
    | keys.Down
    | keys.Left
    | keys.Right
    | keys.Delete
    | keys.Tab
    | keys.BackTab
    | keys.PageUp
    | keys.PageDown
    | keys.Home
    | keys.End
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Unknown(_) -> Continue(state)
  }
}

fn update_confirmation(
  key: keys.Key,
  state: State,
  pending: Proposal,
) -> Action {
  case key {
    keys.Escape -> Continue(State(..state, prompt: EditingTargetStrand))
    keys.Left | keys.Right | keys.Tab ->
      Continue(
        State(..state, wake: case state.wake {
          BusyOnly -> MayWake
          MayWake -> BusyOnly
        }),
      )
    keys.Enter -> Link(Proposal(..pending, wake: state.wake))
    keys.Up
    | keys.Down
    | keys.Backspace
    | keys.Delete
    | keys.BackTab
    | keys.PageUp
    | keys.PageDown
    | keys.Home
    | keys.End
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Char(_)
    | keys.Unknown(_) -> Continue(state)
  }
}

/// Renders the chooser, exact grant directions and the currently active question.
///
/// ## Examples
///
/// ```gleam
/// let frame = peer_links.render(buffer, screen, state)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, state: State) -> buffer.Buffer {
  let width = int.max(1, int.min(100, screen.size.width - 4))
  let height = int.max(7, int.min(22, screen.size.height - 2))
  let area = geometry.centered_rect(width, height, screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [span.span_styled(" PEER LINKS ", theme.overlay_signal())],
      block.Top,
    )
  let inside = block.inner(area, frame)
  let lines = render_lines(state, inside.size.width, inside.size.height)
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_styled(inside, lines)
}

fn render_lines(state: State, width: Int, height: Int) {
  let content = case state.prompt {
    Browsing -> listing_lines(state, width)
    ChoosingSession -> session_lines(state, width)
    EditingTargetStrand -> [
      plain("Target strand: " <> state.target_strand <> "▏"),
      quiet("Type the exact strand name · Enter continues · Esc returns"),
    ]
    Confirming(proposal) -> confirmation_lines(state, proposal)
  }
  let footer = case state.prompt {
    Browsing -> {
      let continuation = case state.next_cursor {
        Some(_) -> " · n load more"
        None -> ""
      }
      quiet(
        "↑↓ select · d revoke · l link · v reverse · r refresh · p from agents"
        <> continuation
        <> " · Esc close",
      )
    }
    ChoosingSession ->
      quiet("↑↓ select resident · Enter · n load more · Esc back")
    EditingTargetStrand -> quiet("Exact strand name · Enter review · Esc back")
    Confirming(_) ->
      quiet(
        "←→ or Tab wake permission · Enter create this direction · Esc back",
      )
  }
  let result = case state.operation_result {
    Some(message) -> [quiet(text.truncate(message, width, "…"))]
    None -> []
  }
  let footers =
    list.append(result, [
      quiet(text.truncate(text_hygiene.single_line(state.notice), width, "…")),
      footer,
    ])
  let room = int.max(0, height - list.length(footers))
  let visible = case state.prompt {
    Browsing -> grant_viewport(content, state.selected_grant, room)
    ChoosingSession -> row_viewport(content, state.selected_session, 3, room)
    EditingTargetStrand | Confirming(_) -> list.take(content, room)
  }
  list.append(visible, footers)
}

// Reserve the source heading, then move whole grant rows under the cursor.
fn grant_viewport(content, selected: Int, room: Int) {
  case list.length(content) <= 3 {
    True -> list.take(content, room)
    False -> {
      let heading = case room >= 3 {
        True -> list.take(content, 1)
        False -> []
      }
      let rows = list.drop(content, 2)
      let row_room = int.max(0, room - list.length(heading))
      list.append(heading, row_viewport(rows, selected, 2, row_room))
    }
  }
}

// The selected row always remains visible, even when the modal is narrow.
fn row_viewport(content, selected: Int, row_height: Int, room: Int) {
  let rows_per_page = int.max(1, room / row_height)
  let first = selected / rows_per_page * rows_per_page
  content
  |> list.drop(first * row_height)
  |> list.take(room)
}

fn listing_lines(state: State, width: Int) {
  let rows = grants(state.inspection)
  let header =
    quiet("Source " <> state.source_session <> "/" <> state.source_strand)
  let rendered =
    list.index_map(rows, fn(grant, index) { #(grant, index) })
    |> list.flat_map(fn(pair) {
      let #(grant, index) = pair
      let marker = case index == state.selected_grant {
        True -> "› "
        False -> "  "
      }
      let direction = case
        grant.source_session == state.source_session
        && grant.source_strand == state.source_strand
      {
        True -> "out "
        False -> "in  "
      }
      let availability = case grant.availability {
        Available -> "resident"
        Unavailable(reason) -> "unavailable: " <> reason
      }
      [
        quiet(text.truncate(
          marker
            <> direction
            <> "from "
            <> grant.source_session
            <> "/"
            <> grant.source_strand,
          width,
          "…",
        )),
        quiet(text.truncate(
          "    to "
            <> grant.target_session
            <> "/"
            <> grant.target_strand
            <> " · "
            <> wake_label(grant.wake)
            <> " · "
            <> availability,
          width,
          "…",
        )),
      ]
    })
  case rendered {
    [] -> [
      header,
      quiet("No incoming or outgoing grants for this strand."),
      quiet("Each page is fresh; the daemon rechecks every mutation."),
    ]
    rows -> [
      header,
      quiet("Each page is fresh; the daemon rechecks every mutation."),
      ..rows
    ]
  }
}

fn session_lines(state: State, width: Int) {
  let rows =
    list.index_map(state.sessions, fn(row, index) { #(row, index) })
    |> list.flat_map(fn(pair) {
      let #(row, index) = pair
      let marker = case index == state.selected_session {
        True -> "› "
        False -> "  "
      }
      let availability = case row.status {
        Resident(_) -> "resident"
        _ -> "unavailable · saved sessions are not opened here"
      }
      [
        quiet(text.truncate(
          marker <> row.name <> " · " <> availability,
          width,
          "…",
        )),
        quiet(text.truncate("    id " <> row.session_id, width, "…")),
        quiet(text.truncate("    workspace " <> row.workspace, width, "…")),
      ]
    })
  case rows {
    [] -> [
      quiet("No resident sessions are available. No saved session was opened."),
    ]
    rows -> rows
  }
}

fn confirmation_lines(state: State, pending: Proposal) {
  [
    plain(
      "Grant "
      <> pending.source_session
      <> "/"
      <> pending.source_strand
      <> " → "
      <> pending.target_session
      <> "/"
      <> pending.target_strand,
    ),
    plain("Wake permission: " <> wake_choice_label(state.wake)),
    quiet("busy_only means during an active run"),
    quiet("may_wake also starts an idle strand"),
  ]
}

/// Decodes one owner-only inspect page into exact directions.
///
/// ## Examples
///
/// ```gleam
/// let page = peer_links.decode_inspection_page(document, "session", "main")
/// ```
pub fn decode_inspection_page(
  document: json.JsonValue,
  source_session: String,
  source_strand: String,
) -> Result(InspectionPage, String) {
  use fields <- result.try(object(document))
  use outgoing_value <- result.try(field(fields, "outgoing"))
  use incoming_value <- result.try(field(fields, "incoming"))
  use next_value <- result.try(field(fields, "next"))
  use outgoing_rows <- result.try(array(outgoing_value))
  use incoming_rows <- result.try(array(incoming_value))
  use outgoing <- result.try(
    list.try_map(outgoing_rows, fn(row) {
      decode_outgoing(row, source_session, source_strand)
    }),
  )
  use incoming <- result.try(
    list.try_map(incoming_rows, fn(row) {
      decode_incoming(row, source_session, source_strand)
    }),
  )
  use next <- result.try(cursor_at(next_value))
  Ok(InspectionPage(Inspection(outgoing:, incoming:), next))
}

/// Decodes the grant portion of a page without exposing its cursor.
///
/// ## Examples
///
/// ```gleam
/// let inspection = peer_links.decode_inspection(document, "session", "main")
/// ```
pub fn decode_inspection(
  document: json.JsonValue,
  source_session: String,
  source_strand: String,
) -> Result(Inspection, String) {
  use page <- result.try(decode_inspection_page(
    document,
    source_session,
    source_strand,
  ))
  Ok(page.inspection)
}

fn decode_outgoing(value, source_session, source_strand) {
  use fields <- result.try(object(value))
  use target_session <- result.try(text_at(fields, "session"))
  use target_strand <- result.try(text_at(fields, "target_strand"))
  use wake <- result.try(optional_wake_at(fields, "wake"))
  use availability <- result.try(availability_at(fields))
  Ok(Grant(
    source_session:,
    source_strand:,
    target_session:,
    target_strand:,
    wake:,
    availability:,
  ))
}

fn decode_incoming(value, target_session, target_strand) {
  use fields <- result.try(object(value))
  use source_session <- result.try(text_at(fields, "source_session"))
  use source_strand <- result.try(text_at(fields, "source_strand"))
  use wake <- result.try(wake_at(fields, "wake"))
  use availability <- result.try(availability_at(fields))
  Ok(Grant(
    source_session:,
    source_strand:,
    target_session:,
    target_strand:,
    wake: Some(wake),
    availability:,
  ))
}

fn grants(optional: Option(Inspection)) -> List(Grant) {
  case optional {
    Some(inspection) -> list.append(inspection.outgoing, inspection.incoming)
    None -> []
  }
}

fn merge_grants(previous: List(Grant), additions: List(Grant)) -> List(Grant) {
  list.fold(additions, previous, fn(rows, addition) {
    let exists = list.any(rows, fn(row) { same_grant(row, addition) })
    case exists {
      True ->
        list.map(rows, fn(row) {
          case same_grant(row, addition) {
            True -> addition
            False -> row
          }
        })
      False -> list.append(rows, [addition])
    }
  })
}

fn same_grant(left: Grant, right: Grant) -> Bool {
  left.source_session == right.source_session
  && left.source_strand == right.source_strand
  && left.target_session == right.target_session
  && left.target_strand == right.target_strand
}

fn proposal(state: State) -> Proposal {
  case item_at(state.sessions, state.selected_session) {
    Ok(row) ->
      Proposal(
        source_session: state.source_session,
        source_strand: state.source_strand,
        target_session: row.session_id,
        target_strand: state.target_strand,
        wake: state.wake,
      )
    Error(Nil) ->
      Proposal(
        source_session: state.source_session,
        source_strand: state.source_strand,
        target_session: "",
        target_strand: state.target_strand,
        wake: state.wake,
      )
  }
}

fn reverse_proposal(state: State, rows: List(Grant)) -> Action {
  case item_at(rows, state.selected_grant) {
    Ok(grant)
      if grant.source_session == state.source_session
      && grant.source_strand == state.source_strand
    ->
      Continue(
        State(
          ..state,
          wake: BusyOnly,
          prompt: Confirming(Proposal(
            source_session: grant.target_session,
            source_strand: grant.target_strand,
            target_session: grant.source_session,
            target_strand: grant.source_strand,
            wake: BusyOnly,
          )),
        ),
      )
    _ ->
      Continue(
        State(..state, notice: "select an outgoing grant to add its reverse"),
      )
  }
}

fn availability_at(fields) {
  case field(fields, "metadata") {
    Ok(json.Object(metadata)) ->
      case list.key_find(metadata, "unavailable") {
        Ok(json.String(reason)) -> Ok(Unavailable(reason))
        _ ->
          case list.key_find(metadata, "status") {
            Ok(json.String("saved")) -> Ok(Unavailable("saved"))
            Ok(json.String("stopping")) -> Ok(Unavailable("stopping"))
            Ok(json.String("blocked")) -> Ok(Unavailable("blocked"))
            _ -> Ok(Available)
          }
      }
    Ok(json.Null) -> Ok(Unavailable("not resident"))
    Ok(_) -> Ok(Available)
    Error(_) -> Ok(Unavailable("not reported"))
  }
}

fn wake_at(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.String("busy_only") -> Ok(BusyOnly)
    json.String("may_wake") -> Ok(MayWake)
    _ -> Error("invalid peer wake permission")
  }
}

fn optional_wake_at(fields, key) {
  case field(fields, key) {
    Ok(json.Null) -> Ok(None)
    Ok(json.String("busy_only")) -> Ok(Some(BusyOnly))
    Ok(json.String("may_wake")) -> Ok(Some(MayWake))
    _ -> Error("invalid peer wake permission")
  }
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected peer inspection object")
  }
}

fn array(value) {
  case value {
    json.Array(values) ->
      case list.length(values) <= 128 {
        True -> Ok(values)
        False -> Error("peer inspection exceeds its grant bound")
      }
    _ -> Error("expected peer inspection list")
  }
}

fn field(fields, name) {
  list.key_find(fields, name)
  |> result.map_error(fn(_) { "missing peer field " <> name })
}

fn cursor_at(value: json.JsonValue) -> Result(Option(String), String) {
  case value {
    json.Null -> Ok(None)
    json.String(cursor) -> Ok(Some(cursor))
    _ -> Error("invalid peer inspection cursor")
  }
}

fn text_at(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.String(text) ->
      case string.byte_size(text) <= 4096 {
        True -> Ok(text)
        False -> Error("invalid peer text field " <> name)
      }
    _ -> Error("invalid peer text field " <> name)
  }
}

fn is_resident(row: Session) {
  case row.status {
    Resident(_) -> True
    _ -> False
  }
}

fn last_grant(inspection: Inspection) -> Int {
  int.max(
    0,
    list.length(list.append(inspection.outgoing, inspection.incoming)) - 1,
  )
}

fn wrap_up(index, rows) {
  case list.length(rows) {
    0 -> 0
    count if index <= 0 -> count - 1
    _ -> index - 1
  }
}

fn wrap_down(index, rows) {
  case list.length(rows) {
    0 -> 0
    count if index >= count - 1 -> 0
    _ -> index + 1
  }
}

fn item_at(rows, index) {
  rows |> list.drop(index) |> list.first
}

fn drop_last_grapheme(value) {
  value
  |> string.to_graphemes
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.concat
}

fn wake_label(wake: Option(PeerWake)) -> String {
  case wake {
    Some(BusyOnly) -> "busy_only"
    Some(MayWake) -> "may_wake"
    None -> "unavailable"
  }
}

fn wake_choice_label(wake: PeerWake) -> String {
  case wake {
    BusyOnly -> "busy_only · during an active run"
    MayWake -> "may_wake · also start an idle strand"
  }
}

fn plain(value) {
  span.line_new([
    span.span_styled(text_hygiene.single_line(value), theme.overlay_plain()),
  ])
}

fn quiet(value) {
  span.line_new([
    span.span_styled(text_hygiene.single_line(value), theme.overlay_quiet()),
  ])
}
