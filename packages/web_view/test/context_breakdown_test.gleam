//// The context breakdown the top bar's figure opens: what it draws from a
//// board, which buttons a page gets, and where the Refresh button's handler
//// sits, since the observer's socket admits a click at that one path.
////
//// The board is built here rather than decoded, so each test names exactly
//// the numbers it draws from.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element.{type Element}
import lustre/element/html
import session_view/context_view
import web_view/component
import web_view/view/context_breakdown
import web_view/view/heading

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

type Cache

@external(erlang, "lane_memo_ffi", "first")
fn first(view: Element(message)) -> Cache

@external(erlang, "lane_memo_ffi", "patch_text")
fn patch(
  cache: Cache,
  old: Element(message),
  new: Element(message),
) -> #(String, Cache)

@external(erlang, "render_memo_ffi", "context_counted")
fn counted(run: fn() -> value) -> #(value, Int)

fn board(items: List(context_view.Item)) -> context_view.Board {
  context_view.Board(
    request_id: 4,
    strand: "main",
    as_of: 42,
    model: "provider/large",
    window: 1_000_000,
    used: 550_000,
    basis: "reported_plus_estimate",
    compaction_used: 550_000,
    checkpoint_at: Some(960_000),
    reserve: 40_000,
    categories: [
      context_view.Item("System prompt", "System prompt", 12_000),
      context_view.Item("Tools", "Tools", 20_000),
      context_view.Item("Messages", "Messages", 500_000),
    ],
    items:,
    omitted: 0,
  )
}

fn observed(board: context_view.Board) -> context_view.State {
  context_view.State(
    ..context_view.new(),
    board: Some(board),
    request: context_view.Idle,
    notice: "",
  )
}

fn drawn(state: context_view.State, compact: option.Option(Nil)) -> String {
  context_breakdown.panel(
    state,
    context_breakdown.Actions(refresh: Nil, compact:),
  )
  |> element.to_string
}

// The headline is the figure the bar shows with the window beside it, and the
// words say where the number comes from and how long until compaction.
pub fn the_headline_and_the_boundary_are_in_plain_words_test() {
  let html = drawn(observed(board([])), None)
  assert string.contains(html, "Context window ~550.0k / 1.0m (55%)")
  assert string.contains(
    html,
    "The count the model provider reported for the last request",
  )
  assert string.contains(
    html,
    "410.0k tokens until the session compacts itself.",
  )
  assert string.contains(html, "need not add up")
}

// Compaction turned off says so and draws no reserve row.
pub fn compaction_off_draws_no_reserve_test() {
  let off = context_view.Board(..board([]), checkpoint_at: None, reserve: 0)
  let html = drawn(observed(off), None)
  assert string.contains(html, "Automatic compaction is off.")
  assert !string.contains(html, "Compaction reserve")
}

// The window is cut into the three rows, the reserve and what is free, and
// what the provider counted beyond the rows is its own part, so the parts
// always add up to the window.
pub fn the_window_labels_into_rows_reserve_and_free_space_test() {
  let split = context_breakdown.split(board([]))
  assert split.system == 12_000
  assert split.tools == 20_000
  assert split.messages == 500_000
  assert split.unattributed == 18_000
  assert split.reserve == 40_000
  assert split.free == 410_000
  assert split.system
    + split.tools
    + split.messages
    + split.unattributed
    + split.reserve
    + split.free
    == 1_000_000
}

// Estimates larger than the headline never push free space below zero.
pub fn free_space_never_goes_negative_test() {
  let crowded =
    context_view.Board(..board([]), used: 100, window: 600_000, reserve: 40_000)
  let split = context_breakdown.split(crowded)
  assert split.free == 600_000 - 532_000 - 40_000
  assert split.unattributed == 0
  let over = context_view.Board(..crowded, window: 500_000)
  assert context_breakdown.split(over).free == 0
}

// Tools are listed by name, largest first, and messages are grouped by kind
// with their places dropped, so a hundred assistant messages are one row.
pub fn the_inventory_groups_by_tool_and_by_kind_test() {
  let items = [
    context_view.Item("Tools", "bash", 700),
    context_view.Item("Tools", "read", 900),
    context_view.Item("Messages", "1. User / injected context", 300),
    context_view.Item("Messages", "2. Assistant", 100),
    context_view.Item("Messages", "3. Tool result: read", 4000),
    context_view.Item("Messages", "4. Assistant", 150),
  ]
  let observation = board(items)
  assert context_breakdown.tools(observation)
    == [#("read", 900, 1), #("bash", 700, 1)]
  assert context_breakdown.kinds(observation)
    == [
      #("Tool result: read", 4000, 1),
      #("User / injected context", 300, 1),
      #("Assistant", 250, 2),
    ]
}

// Only the first rows are drawn and the rest are counted.
pub fn the_inventory_is_bounded_test() {
  let items =
    list.index_map(list.repeat(0, 12), fn(_, offset) {
      let index = offset + 1
      context_view.Item(
        "Tools",
        "tool-" <> string.pad_start(string.inspect(index), 2, "0"),
        100 + index,
      )
    })
  let html = drawn(observed(board(items)), None)
  assert string.contains(html, "tool-12")
  assert !string.contains(html, "tool-01<")
  assert string.contains(html, "4 more")
}

// A tool's name and a message's kind come from the session and are drawn as
// text, so markup in one is escaped and nothing reaches an attribute.
pub fn session_text_is_drawn_as_text_test() {
  let items = [
    context_view.Item("Tools", "<img src=x onerror=alert(1)>", 500),
    context_view.Item("Messages", "1. Custom: <script>", 200),
  ]
  let html = drawn(observed(board(items)), None)
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")
  assert string.contains(html, "Custom: &lt;script&gt;")
  assert !string.contains(html, "<img")
  assert !string.contains(html, "<script")
}

// An omitted tail is said, so a grouped list is not read as the whole.
pub fn omitted_items_are_said_test() {
  let html = drawn(observed(context_view.Board(..board([]), omitted: 7)), None)
  assert string.contains(html, "7 items are left out of this list")
}

// Compact now is drawn when the page hands a message for it and not
// otherwise; Refresh is always there.
pub fn compact_now_is_drawn_only_where_the_page_offers_it_test() {
  let without = drawn(observed(board([])), None)
  assert string.contains(without, ">Refresh</button>")
  assert !string.contains(without, "Compact now")
  let with = drawn(observed(board([])), Some(Nil))
  assert string.contains(with, ">Compact now</button>")
}

// Before a board arrives the panel says so in words and still offers Refresh.
// A refused compaction leaves its sentence under the buttons until the next
// press clears it, and a panel that was never refused draws no such line.
pub fn a_compaction_with_nothing_to_cut_is_said_under_the_buttons_test() {
  let state = observed(board([]))
  assert !string.contains(drawn(state, Some(Nil)), "Nothing to compact yet.")

  let refused = context_view.nothing_to_compact(state)
  let panel = drawn(refused, Some(Nil))
  assert string.contains(panel, "Nothing to compact yet.")
  assert string.contains(panel, "role=\"status\"")

  let asked = context_view.compact_asked(refused)
  assert !string.contains(drawn(asked, Some(Nil)), "Nothing to compact yet.")
}

pub fn no_board_says_so_and_offers_refresh_test() {
  let html = drawn(context_view.new(), None)
  assert string.contains(html, "Reading the context.")
  assert string.contains(html, ">Refresh</button>")
  let unsupported =
    context_view.State(
      ..context_view.new(),
      request: context_view.Unavailable,
      notice: "",
    )
  assert string.contains(
    drawn(unsupported, None),
    "does not offer a context observation",
  )
}

// The bar as the page draws it, wrapped so that its paths read from the same
// root the page's do: the frame is the root and the bar its first child.
fn bar(compact: option.Option(Nil)) -> Element(Nil) {
  html.div([], [
    heading.view(
      session_id: "0192ab34cd",
      home: element.none(),
      name: None,
      workspace: None,
      model: Some("baseten-glm-5-3"),
      status: "connected",
      tone: heading.Live,
      context: "ctx ~55%",
      breakdown: context_breakdown.panel(
        observed(board([])),
        context_breakdown.Actions(refresh: Nil, compact:),
      ),
      cost: "est $0.04",
      notice: element.none(),
    ),
  ])
}

// The Refresh button's handler is at `component.context_refresh_path`, which
// the observer's socket admits a click at, and the Compact now handler is the
// next sibling and is drawn only when the page offers it. The cost figure
// beside the context figure draws no handler of its own.
pub fn the_buttons_are_at_the_paths_the_socket_names_test() {
  let refresh = component.context_refresh_path <> "\nclick"
  let compact = string.drop_end(component.context_refresh_path, 1) <> "1\nclick"
  let observer = every_handler(bar(None))
  assert observer == [refresh]
  let operator = every_handler(bar(Some(Nil)))
  assert list.sort(operator, string.compare)
    == list.sort([refresh, compact], string.compare)
}

// Stream-driven headings reuse the inventory while unrelated state changes.
pub fn unchanged_inventory_does_no_label_grouping_work_test() {
  let initial =
    observed(
      board([
        context_view.Item("Messages", "1. Assistant", 100),
        context_view.Item("Tools", "read", 200),
      ]),
    )
  let actions = context_breakdown.Actions(refresh: "refresh", compact: None)
  let #(#(view, cache), labels) =
    counted(fn() {
      let view = context_breakdown.panel(initial, actions)
      #(view, first(view))
    })
  assert labels > 0

  let next =
    observed(
      context_view.Board(
        ..board([
          context_view.Item("Messages", "1. Assistant", 100),
          context_view.Item("Tools", "read", 200),
        ]),
        used: 600_000,
        as_of: 43,
      ),
    )
  let #(#(next_view, text, cache), labels) =
    counted(fn() {
      let next_view =
        context_breakdown.panel(
          next,
          context_breakdown.Actions(
            refresh: "refresh",
            compact: Some("compact"),
          ),
        )
      let #(text, next_cache) = patch(cache, view, next_view)
      #(next_view, text, next_cache)
    })
  assert list.length(every_handler(view)) == 1
  assert list.length(every_handler(next_view)) == 2
  assert labels == 0
  assert string.contains(text, "600.0k")

  let #(#(_, _), labels) =
    counted(fn() {
      patch(cache, next_view, context_breakdown.panel(next, actions))
    })
  assert labels == 0
}

// Every inventory input invalidates the leaf; text stays escaped after reuse.
pub fn inventory_changes_refresh_labels_tokens_and_omissions_test() {
  let original =
    observed(
      board([
        context_view.Item("Messages", "1. Assistant", 100),
      ]),
    )
  let actions = context_breakdown.Actions(refresh: "refresh", compact: None)
  let old = context_breakdown.panel(original, actions)
  let cache = first(old)
  let changed =
    context_breakdown.panel(
      observed(
        board([
          context_view.Item("Messages", "2. Tool result: <script>", 900),
        ]),
      ),
      actions,
    )
  let #(#(text, cache), labels) = counted(fn() { patch(cache, old, changed) })
  assert labels > 0
  assert string.contains(text, "Tool result: <script>")
  assert string.contains(element.to_string(changed), "&lt;script&gt;")
  assert !string.contains(element.to_string(changed), "<script>")
  assert string.contains(text, "900")

  let repriced =
    context_breakdown.panel(
      observed(
        board([
          context_view.Item("Messages", "2. Tool result: <script>", 1900),
        ]),
      ),
      actions,
    )
  let #(#(text, cache), labels) =
    counted(fn() { patch(cache, changed, repriced) })
  assert labels > 0
  assert string.contains(text, "1.9k")

  let omitted =
    context_breakdown.panel(
      observed(
        context_view.Board(
          ..board([
            context_view.Item("Messages", "2. Tool result: <script>", 1900),
          ]),
          omitted: 7,
        ),
      ),
      actions,
    )
  let #(text, cache) = patch(cache, repriced, omitted)
  assert string.contains(text, "7 items are left out")
  let empty = context_breakdown.panel(observed(board([])), actions)
  let #(text, _) = patch(cache, omitted, empty)
  assert !string.contains(element.to_string(empty), "&lt;script&gt;")
  assert string.length(text) > 0
}
