//// The panel the top bar's context figure opens: what fills the model's
//// window, in the words and numbers the terminal's context panel shows
//// (`tui/context_panel`), as one stacked bar and a few rows.
////
//// The figure is a native `<details>`: its summary is the `ctx ~41%` words
//// and its body is this panel, so opening and closing it is the browser's own
//// and costs the server nothing. The panel is drawn from the board the shared
//// record already holds (`context_view.State`), the same server-priced
//// observation the figure reads, so the two cannot disagree. It reads nothing
//// else and decides nothing; the page's controls are the two messages it is
//// handed.
////
//// ## Flow
////
//// `panel` draws the whole body. `actions_row` is the row of its two buttons,
//// `bar` and `legend` are the stacked bar and the rows beneath it,
//// `inventory` owns the leaf memo; `inventory_list` draws its collapsible
//// item list. `message_items` and `tool_items` group the referenced items,
//// and `kinds` and `tools` expose those groupings for a complete board. `split` is the arithmetic every figure
//// shares: the window cut into the segments the bar draws.
////
//// ## What the numbers mean
////
//// The headline is the server's estimate of the strand's context: the
//// provider's own count of the last request plus an estimate of the messages
//// that came after it, or an estimate of everything when the provider has
//// reported nothing. The rows beneath it are estimated one by one, from the
//// prompt, the tool definitions and the messages, so they are not parts of
//// the headline and need not add up to it. The bar says so in words, and
//// where the provider's count exceeds what the rows account for it draws the
//// difference as its own segment rather than stretching a row.
////
//// ## What may be drawn
////
//// Tool names and message kinds come from the session, so each is a text node
//// and nothing else. A percentage written into a `style` attribute is an
//// integer this module computed, never text from the board.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/agent_roster
import session_view/context_view
import session_view/text_hygiene

/// The most rows either grouping of the item list draws before it says how
/// many it left out.
pub const listed_rows = 8

/// The two messages the panel's buttons send, which the page's own message
/// type supplies because this module cannot import it.
pub type Actions(message) {
  Actions(
    /// What the Refresh button sends: a fresh read of the board.
    refresh: message,
    /// What the Compact now button sends, or `None` on a page whose reader
    /// may not compact the session. A page that cannot run `/compact` draws
    /// no button for it.
    compact: Option(message),
  )
}

/// The window cut into the parts the bar draws, in tokens.
///
/// `occupied` is the larger of the headline and the sum of the rows, so the
/// bar never draws more than the window holds when the two disagree, and
/// `unattributed` is what the headline holds beyond the rows. Nothing here is
/// scaled: each part is the board's own number or a difference of two.
pub type Split {
  Split(
    /// The pinned prompt's estimate.
    system: Int,
    /// The active tool definitions' estimate.
    tools: Int,
    /// The messages' estimate.
    messages: Int,
    /// What the headline holds beyond the three rows, when it holds more.
    unattributed: Int,
    /// The space held back for the next response, which compaction waits
    /// for. Zero when automatic compaction is off.
    reserve: Int,
    /// What remains of the window once the rest is taken out.
    free: Int,
  )
}

/// The panel's body: the two buttons, then the board, or the words saying
/// there is no board.
///
/// ## Examples
///
/// ```gleam
/// // context_breakdown.panel(state, Actions(refresh: Refresh, compact: None))
/// ```
pub fn panel(
  state: context_view.State,
  actions: Actions(message),
) -> Element(message) {
  html.div(
    [attribute.class("ctx-panel"), attribute.aria_label("Context window")],
    [
      actions_row(actions),
      case state.board {
        None ->
          html.p([attribute.class("ctx-note")], [
            html.text(unavailable_words(state)),
          ])
        Some(board) -> board_view(state, board)
      },
    ],
  )
}

// The Refresh button and, on a page that may compact, the Compact now button.
// They are the panel's first child so that their place does not depend on
// whether a board has arrived, which is what lets the page socket name the
// Refresh button's path (`component.context_refresh_path`).
fn actions_row(actions: Actions(message)) -> Element(message) {
  html.div([attribute.class("ctx-actions")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("ctx-button"),
        attribute.title("Read the context again from the session"),
        event.on_click(actions.refresh),
      ],
      [html.text("Refresh")],
    ),
    case actions.compact {
      Some(press) ->
        html.button(
          [
            attribute.type_("button"),
            attribute.class("ctx-button"),
            attribute.title("Summarise older messages now, as /compact does"),
            event.on_click(press),
          ],
          [html.text("Compact now")],
        )
      None -> element.none()
    },
  ])
}

// What the panel says when no board is held: the host's own notice or the
// state of the read, in words.
fn unavailable_words(state: context_view.State) -> String {
  case state.request, state.notice {
    context_view.Unavailable, _ ->
      "This daemon does not offer a context observation."
    context_view.Requested, _
    | context_view.Awaiting(_), _
    | context_view.RefreshAfter(_), _
    -> "Reading the context."
    _, "" -> "The context has not been observed."
    _, notice -> text_hygiene.single_line(notice)
  }
}

// How the board's reading stands: a read out means the figures may be stale.
fn freshness_words(
  state: context_view.State,
  board: context_view.Board,
) -> String {
  case state.request {
    context_view.Requested
    | context_view.Awaiting(_)
    | context_view.RefreshAfter(_) -> "Refreshing; these figures may be stale."
    context_view.Idle | context_view.Unavailable ->
      "Observed at durable sequence " <> int.to_string(board.as_of) <> "."
  }
}

// The board's whole drawing, from the headline to the item list.
fn board_view(
  state: context_view.State,
  board: context_view.Board,
) -> Element(message) {
  let split = split(board)
  element.fragment([
    html.h2([attribute.class("ctx-headline")], [
      html.text(
        "Context window ~"
        <> agent_roster.count_label(board.used)
        <> " / "
        <> agent_roster.count_label(board.window)
        <> " ("
        <> int.to_string(board.used * 100 / board.window)
        <> "%)",
      ),
    ]),
    html.p([attribute.class("ctx-note")], [html.text(basis_words(board))]),
    bar(board, split),
    legend(board, split),
    html.p([attribute.class("ctx-until")], [html.text(until_words(board))]),
    html.p([attribute.class("ctx-note")], [
      html.text(
        "The rows are estimated one by one, so they need not add up to the figure above. Hooks and text not yet sent are not counted.",
      ),
    ]),
    inventory(board),
    html.p([attribute.class("ctx-note")], [
      html.text(
        text_hygiene.single_line(board.model)
        <> " · strand "
        <> text_hygiene.single_line(board.strand)
        <> " · "
        <> freshness_words(state, board),
      ),
    ]),
  ])
}

// Where the headline's number comes from, in plain words.
fn basis_words(board: context_view.Board) -> String {
  case board.basis {
    "reported_plus_estimate" ->
      "The count the model provider reported for the last request, plus an estimate for the messages added since."
    _ ->
      "An estimate from the prompt, the tools and the messages; the provider has reported no count yet."
  }
}

// How much room is left before the session compacts itself, or that it will
// not. The threshold is the window less the reserve, and the count it is
// measured against is the one compaction itself uses.
fn until_words(board: context_view.Board) -> String {
  case board.checkpoint_at {
    Some(at) ->
      agent_roster.count_label(int.max(0, at - board.compaction_used))
      <> " tokens until the session compacts itself."
    None -> "Automatic compaction is off."
  }
}

/// Cuts the board's window into the parts the bar draws.
///
/// The rows are the board's categories by name. A category the board does
/// not name is zero, so an older daemon's board draws a smaller bar and does
/// not fail. `free` never goes below zero, since the estimates can exceed
/// the window.
///
/// ## Examples
///
/// ```gleam
/// // context_breakdown.split(board)
/// ```
pub fn split(board: context_view.Board) -> Split {
  let system = category(board, "System prompt")
  let tools = category(board, "Tools")
  let messages = category(board, "Messages")
  let rows = system + tools + messages
  let occupied = int.max(board.used, rows)
  Split(
    system:,
    tools:,
    messages:,
    unattributed: int.max(0, board.used - rows),
    reserve: board.reserve,
    free: int.max(0, board.window - occupied - board.reserve),
  )
}

// One category's tokens, or nothing when the board names none.
fn category(board: context_view.Board, name: String) -> Int {
  case list.find(board.categories, fn(item) { item.name == name }) {
    Ok(item) -> item.tokens
    Error(Nil) -> 0
  }
}

// The stacked bar: one segment for every part that holds tokens, each as wide
// as its share of the window. The bar is an image for a screen reader, which
// the legend beneath it reads in full.
fn bar(board: context_view.Board, split: Split) -> Element(message) {
  html.div(
    [
      attribute.class("ctx-bar"),
      attribute.role("img"),
      attribute.aria_label("How the context window is used"),
    ],
    list.filter_map(parts(split), fn(part) {
      case part.1 > 0 {
        True -> Ok(segment(part.0, part.1, board.window))
        False -> Error(Nil)
      }
    }),
  )
}

// One part of the window: its class, its tokens.
fn parts(split: Split) -> List(#(Part, Int)) {
  [
    #(SystemPrompt, split.system),
    #(Tools, split.tools),
    #(Messages, split.messages),
    #(Unattributed, split.unattributed),
    #(Reserve, split.reserve),
    #(Free, split.free),
  ]
}

// The parts of the window a row and a segment can name. The class of each is
// a complete literal so the stylesheet's source scan finds it.
type Part {
  SystemPrompt
  Tools
  Messages
  Unattributed
  Reserve
  Free
}

fn part_class(part: Part) -> String {
  case part {
    SystemPrompt -> "ctx-system"
    Tools -> "ctx-tools"
    Messages -> "ctx-messages"
    Unattributed -> "ctx-other"
    Reserve -> "ctx-reserve"
    Free -> "ctx-free"
  }
}

fn part_name(part: Part) -> String {
  case part {
    SystemPrompt -> "System prompt"
    Tools -> "Tools"
    Messages -> "Messages"
    Unattributed -> "Counted by the provider, not itemised"
    Reserve -> "Compaction reserve"
    Free -> "Free space"
  }
}

// One segment of the bar. Its width is an integer percentage this module
// computed, so the `style` attribute holds nothing the board wrote.
fn segment(part: Part, tokens: Int, window: Int) -> Element(message) {
  html.span(
    [
      attribute.class("ctx-segment"),
      attribute.class(part_class(part)),
      attribute.style("width", int.to_string(share(tokens, window)) <> "%"),
    ],
    [],
  )
}

// A part's width on the bar. A part that holds tokens is at least one percent
// wide so it can be seen, and none is wider than the window.
fn share(tokens: Int, window: Int) -> Int {
  int.clamp(tokens * 100 / window, 1, 100)
}

// The rows under the bar: a swatch, the part's name, its tokens and its share
// of the window. A part with no tokens has no row, which also leaves a
// session with automatic compaction off without a reserve row.
fn legend(board: context_view.Board, split: Split) -> Element(message) {
  html.ul(
    [attribute.class("ctx-legend")],
    list.filter_map(parts(split), fn(part) {
      case part.1 > 0 {
        True -> Ok(row(part.0, part.1, board.window))
        False -> Error(Nil)
      }
    }),
  )
}

fn row(part: Part, tokens: Int, window: Int) -> Element(message) {
  html.li([attribute.class("ctx-row")], [
    html.span(
      [attribute.class("ctx-swatch"), attribute.class(part_class(part))],
      [],
    ),
    html.span([attribute.class("ctx-name")], [html.text(part_name(part))]),
    html.span([attribute.class("ctx-tokens")], [
      html.text(agent_roster.count_label(tokens)),
    ]),
    html.span([attribute.class("ctx-percent")], [
      html.text(percent(tokens, window)),
    ]),
  ])
}

// A share of the window in words. A part too small for a whole percent says
// so rather than drawing a zero beside a row that holds tokens.
fn percent(tokens: Int, window: Int) -> String {
  case tokens * 100 / window {
    0 -> "<1%"
    whole -> int.to_string(whole) <> "%"
  }
}

// The item list: a closed `<details>` holding the tools by name and the
// messages by kind, each the largest rows first and bounded, and a line
// saying how many rows the observation left out. The groupings read only the
// items the board lists, which is a prefix, so a board that omitted some says
// so and the totals above stay the whole.
fn inventory(board: context_view.Board) -> Element(message) {
  let items = board.items
  let omitted = board.omitted

  // The item list changes only with these two inputs. Stream arrivals and
  // freshness updates redraw the heading, but need no regrouping of the same
  // labels. This is a leaf: it holds no handlers or nested memo entries.
  element.memo([element.ref(items), element.ref(omitted)], fn() {
    inventory_list(items, omitted)
  })
}

// Grouping belongs inside the leaf memo, including normalization of every
// untrusted label. Its references cover every value the callback reads.
fn inventory_list(
  items: List(context_view.Item),
  omitted: Int,
) -> Element(message) {
  html.details([attribute.class("ctx-items")], [
    html.summary([], [html.text("What is in the context")]),
    group("Tools", tool_items(items)),
    group("Messages", message_items(items)),
    case omitted {
      0 -> element.none()
      omitted ->
        html.p([attribute.class("ctx-note")], [
          html.text(
            int.to_string(omitted)
            <> " items are left out of this list by the observation's size limit; the figures above count them.",
          ),
        ])
    },
  ])
}

// One titled list of the largest rows, and a line for the ones not drawn.
fn group(title: String, rows: List(#(String, Int, Int))) -> Element(message) {
  case rows {
    [] -> element.none()
    _ ->
      html.section([attribute.class("ctx-group")], [
        html.h3([], [html.text(title)]),
        html.ul(
          [attribute.class("ctx-list")],
          list.map(list.take(rows, listed_rows), fn(entry) {
            html.li([attribute.class("ctx-row")], [
              html.span([attribute.class("ctx-name")], [
                html.text(entry.0 <> count_suffix(entry.2)),
              ]),
              html.span([attribute.class("ctx-tokens")], [
                html.text("~" <> agent_roster.count_label(entry.1)),
              ]),
            ])
          }),
        ),
        case list.length(rows) - listed_rows {
          more if more > 0 ->
            html.p([attribute.class("ctx-note")], [
              html.text(int.to_string(more) <> " more"),
            ])
          _ -> element.none()
        },
      ])
  }
}

// How many items a row stands for, written only when it stands for several.
fn count_suffix(count: Int) -> String {
  case count > 1 {
    True -> " ×" <> int.to_string(count)
    False -> ""
  }
}

/// The tool definitions the board lists, largest first: the tool's name, its
/// tokens, and one item.
///
/// ## Examples
///
/// ```gleam
/// // context_breakdown.tools(board)
/// ```
pub fn tools(board: context_view.Board) -> List(#(String, Int, Int)) {
  tool_items(board.items)
}

// Tool rows read only the item inventory, independent of the board headline.
fn tool_items(items: List(context_view.Item)) -> List(#(String, Int, Int)) {
  items
  |> list.filter(fn(item) { item.category == "Tools" })
  |> list.map(fn(item) {
    #(text_hygiene.single_line(item.name), item.tokens, 1)
  })
  |> largest_first
}

/// The messages the board lists grouped by kind, largest first: the kind,
/// their tokens together, and how many there are.
///
/// An item's name begins with its place in the conversation (`12. Assistant`),
/// which is dropped so that every assistant message falls into one row. A
/// tool result is grouped by the tool it answers.
///
/// ## Examples
///
/// ```gleam
/// // context_breakdown.kinds(board)
/// ```
pub fn kinds(board: context_view.Board) -> List(#(String, Int, Int)) {
  message_items(board.items)
}

// Message groups read only the same inventory the leaf references.
fn message_items(items: List(context_view.Item)) -> List(#(String, Int, Int)) {
  items
  |> list.filter(fn(item) { item.category == "Messages" })
  |> list.fold(dict.new(), fn(groups, item) {
    let kind = text_hygiene.single_line(without_place(item.name))
    let #(tokens, count) = result.unwrap(dict.get(groups, kind), #(0, 0))
    dict.insert(groups, kind, #(tokens + item.tokens, count + 1))
  })
  |> dict.to_list
  |> list.map(fn(entry) { #(entry.0, entry.1.0, entry.1.1) })
  |> largest_first
}

// The kind of a message from its listed name, without the leading place.
fn without_place(name: String) -> String {
  case string.split_once(name, ". ") {
    Ok(#(place, kind)) ->
      case int.parse(place) {
        Ok(_) -> kind
        Error(Nil) -> name
      }
    Error(Nil) -> name
  }
}

// Largest rows first, and equal rows by name so the order does not change
// between two draws of the same board.
fn largest_first(rows: List(#(String, Int, Int))) -> List(#(String, Int, Int)) {
  list.sort(rows, fn(left, right) {
    case int.compare(right.1, left.1) {
      order.Eq -> string.compare(left.0, right.0)
      other -> other
    }
  })
}
