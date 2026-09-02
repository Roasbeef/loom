//// The searchable model-selector overlay.
////
//// The overlay owns only presentation state. Selecting a model returns its
//// catalogue name to the caller, which remains responsible for sending the
//// frozen ClientGateway command.

import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/keys
import etui/span
import etui/style
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/string
import tui/protocol.{type ModelInfo, ModelInfo}
import tui/text_hygiene
import tui/theme

/// The selector's local interaction state.
pub type State {
  State(
    /// The latest authoritative catalogue rows.
    models: List(ModelInfo),
    /// The operator's local, unsent search text.
    query: String,
    /// The zero-based cursor within the filtered rows.
    selected: Int,
  )
}

/// The result of one selector keystroke.
pub type Action {
  /// Keep the overlay open with replacement local state.
  Continue(
    /// The state to render on the next frame.
    state: State,
  )

  /// Close the overlay and request one catalogue model by name.
  Choose(
    /// The selected model's stable catalogue name.
    name: String,
  )

  /// Close the overlay without changing the model configuration.
  Close
}

/// Opens a selector over the latest catalogue.
///
/// ## Examples
///
/// ```gleam
/// let state = model_selector.new(models, "baseten-kimi-k3")
/// ```
pub fn new(models: List(ModelInfo), current: String) -> State {
  State(models:, query: "", selected: selected_model(models, current, 0))
}

/// Replaces catalogue rows while preserving the current query.
///
/// ## Examples
///
/// ```gleam
/// let refreshed = model_selector.replace_models(state, models, current)
/// ```
pub fn replace_models(
  state: State,
  models: List(ModelInfo),
  current: String,
) -> State {
  let visible = filter_models(models, state.query)
  State(
    models:,
    query: state.query,
    selected: selected_model(visible, current, state.selected),
  )
}

/// Handles one key while the selector owns input focus.
///
/// ## Examples
///
/// ```gleam
/// let action = model_selector.update(keys.Down, state)
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  let visible = filter_models(state.models, state.query)
  case key {
    keys.Escape -> Close
    keys.Enter ->
      case item_at(visible, state.selected) {
        Ok(ModelInfo(name:, ..)) -> Choose(name)
        Error(Nil) -> Continue(state)
      }
    keys.Up ->
      Continue(State(..state, selected: wrap_up(state.selected, visible)))
    keys.Down ->
      Continue(State(..state, selected: wrap_down(state.selected, visible)))
    keys.PageUp ->
      Continue(State(..state, selected: int.max(0, state.selected - 8)))
    keys.PageDown ->
      Continue(
        State(
          ..state,
          selected: int.min(last_index(visible), state.selected + 8),
        ),
      )
    keys.Backspace ->
      Continue(
        State(..state, query: drop_last_grapheme(state.query), selected: 0),
      )
    keys.Char(character) ->
      Continue(State(..state, query: state.query <> character, selected: 0))
    keys.Left
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
    | keys.Unknown(_) -> Continue(state)
  }
}

/// Renders the selector above the main interface.
///
/// ## Examples
///
/// ```gleam
/// let next_buffer = model_selector.render(buffer, screen, state)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, state: State) -> buffer.Buffer {
  let visible = filter_models(state.models, state.query)

  // The catalogue is normally short. Sizing to its rows keeps the selector a
  // focused command surface instead of obscuring the transcript with an empty
  // modal field; the cap still turns a large catalogue into a scrolling list.
  let width = int.max(1, int.min(92, screen.size.width - 6))
  let height =
    int.max(7, int.min(16, list.length(visible) + 6))
    |> int.min(int.max(1, screen.size.height - 4))
  let area = geometry.centered_rect(width, height, screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [
        span.span_styled(" MODEL ", overlay_signal()),
        span.span_styled("selector ", overlay_quiet()),
      ],
      block.Top,
    )
    |> block.with_padding(1, 0, 2, 2)
  let inside = block.inner(area, frame)
  case geometry.split_v(inside, [Length(1), Length(1), Fill, Length(1)]) {
    [summary_area, search_area, list_area, help_area] ->
      buf
      |> buffer.clear(area)
      |> block.render(area, frame)
      |> render_summary(summary_area, visible)
      |> render_search(search_area, state.query)
      |> render_models(list_area, visible, state.selected)
      |> render_help(help_area)
    _ -> buf |> buffer.clear(area) |> block.render(area, frame)
  }
}

fn render_summary(
  buf: buffer.Buffer,
  area: Rect,
  models: List(ModelInfo),
) -> buffer.Buffer {
  paragraph.render_text(
    buf,
    area,
    span.text_new([
      span.line_new([
        span.span_styled(int.to_string(list.length(models)), overlay_current()),
        span.span_styled(" matching models", overlay_quiet()),
      ]),
    ]),
  )
}

fn render_search(
  buf: buffer.Buffer,
  area: Rect,
  query: String,
) -> buffer.Buffer {
  let value = case query {
    "" ->
      span.span_styled("Search by name, provider, or model id", overlay_quiet())
    text -> span.span_styled(text, overlay_plain())
  }
  paragraph.render_text(
    buf,
    area,
    span.text_new([
      span.line_new([span.span_styled("/ ", overlay_signal()), value]),
    ]),
  )
}

// The window is one row per catalogue entry, so it must be rendered by rows
// as well. A wrapping render would give a wide row two of them, push the
// selected entry past the clip, and leave the operator navigating a cursor
// they cannot see; each row is instead cut to the overlay width.
fn render_models(
  buf: buffer.Buffer,
  area: Rect,
  models: List(ModelInfo),
  selected: Int,
) -> buffer.Buffer {
  let height = int.max(1, area.size.height)
  let start = int.max(0, selected - height + 1)
  let rows =
    models
    |> list.drop(start)
    |> list.take(height)
    |> list.index_map(fn(model, offset) {
      model_line(model, start + offset == selected, area.size.width)
    })
  let rows = case rows {
    [] -> [
      span.line_new([
        span.span_styled("  no matching models", overlay_quiet()),
      ]),
    ]
    rows -> rows
  }
  paragraph.render_styled(buf, area, rows)
}

fn model_line(model: ModelInfo, selected: Bool, width: Int) -> span.Line {
  let ModelInfo(name:, dialect:, model_id:, active:, ..) = model
  let #(marker, name_style) = case selected {
    True -> #("▸ ", overlay_signal())
    False -> #("  ", overlay_plain())
  }
  let active_badge = case active {
    [] -> ""
    roles -> "  ● " <> string.join(roles, ",")
  }
  let identifier =
    "  "
    <> text_hygiene.single_line(dialect)
    <> "/"
    <> text_hygiene.single_line(model_id)
  let name = text_hygiene.single_line(name)

  // The badge names the roles this row is currently routing, which is the one
  // field an operator is reading the list to check, so it keeps its cells
  // before anything else is measured. The name is what the search box matches
  // against and takes up to half of what is left; whatever it does not use
  // falls to the identifier, whose provider-qualified tail is the part that
  // separates two builds of the same model.
  let budget =
    int.max(1, width - string.length(marker) - string.length(active_badge))
  let name_width = int.min(string.length(name), int.max(1, budget / 2))
  let identifier_width = int.max(0, budget - name_width)

  span.line_new([
    span.span_styled(marker, name_style),
    span.span_styled(text_hygiene.fit_tail(name, name_width), name_style),
    span.span_styled(
      text_hygiene.fit_tail(identifier, identifier_width),
      overlay_quiet(),
    ),
    span.span_styled(active_badge, overlay_current()),
  ])
}

fn render_help(buf: buffer.Buffer, area: Rect) -> buffer.Buffer {
  paragraph.render_text(
    buf,
    area,
    span.text_new([
      span.line_new([
        span.span_styled("↑↓", overlay_signal()),
        span.span_styled(" navigate   ", overlay_quiet()),
        span.span_styled("enter", overlay_signal()),
        span.span_styled(" select   ", overlay_quiet()),
        span.span_styled("esc", overlay_signal()),
        span.span_styled(" close", overlay_quiet()),
      ]),
    ]),
  )
}

fn overlay_signal() -> style.Style {
  theme.overlay_signal()
}

fn overlay_current() -> style.Style {
  theme.overlay_current()
}

fn overlay_quiet() -> style.Style {
  theme.overlay_quiet()
}

fn overlay_plain() -> style.Style {
  theme.overlay_plain()
}

fn filter_models(models: List(ModelInfo), query: String) -> List(ModelInfo) {
  let needle = normalize(query)
  case needle {
    "" -> models
    _ ->
      models
      |> list.filter(fn(model) { match_score(model, needle) > 0 })
      |> list.sort(fn(left, right) {
        int.compare(match_score(right, needle), match_score(left, needle))
      })
  }
}

// Search quality follows the interaction pattern in Prime Agent and Crush:
// exact and prefix matches stay above fuzzy matches, while a subsequence lets
// an operator type initials such as `glm53f` without remembering punctuation.
fn match_score(model: ModelInfo, needle: String) -> Int {
  let ModelInfo(name:, dialect:, model_id:, active:, ..) = model
  let name = normalize(name)
  let catalogue = normalize(name <> dialect <> model_id)
  let quality = case name == needle, string.starts_with(name, needle) {
    True, _ -> 400
    False, True -> 300
    False, False ->
      case string.contains(catalogue, needle) {
        True -> 200
        False ->
          case
            subsequence(
              string.to_graphemes(needle),
              string.to_graphemes(catalogue),
            )
          {
            True -> 100
            False -> 0
          }
      }
  }
  case quality, active {
    0, _ -> 0
    _, [] -> quality
    _, _ -> quality + 10
  }
}

fn subsequence(needle: List(String), haystack: List(String)) -> Bool {
  case needle, haystack {
    [], _ -> True
    _, [] -> False
    [wanted, ..rest], [candidate, ..remaining] ->
      case wanted == candidate {
        True -> subsequence(rest, remaining)
        False -> subsequence(needle, remaining)
      }
  }
}

fn normalize(value: String) -> String {
  value
  |> string.lowercase
  |> string.replace(" ", "")
  |> string.replace("-", "")
  |> string.replace("_", "")
  |> string.replace("/", "")
}

fn selected_model(
  models: List(ModelInfo),
  current: String,
  fallback: Int,
) -> Int {
  let found =
    models
    |> list.index_fold(-1, fn(found, model, index) {
      case found < 0 && model.name == current {
        True -> index
        False -> found
      }
    })
  case found >= 0 {
    True -> found
    False -> int.min(int.max(0, fallback), last_index(models))
  }
}

fn wrap_up(selected: Int, models: List(ModelInfo)) -> Int {
  case selected <= 0 {
    True -> last_index(models)
    False -> selected - 1
  }
}

fn wrap_down(selected: Int, models: List(ModelInfo)) -> Int {
  case selected >= last_index(models) {
    True -> 0
    False -> selected + 1
  }
}

fn last_index(models: List(a)) -> Int {
  int.max(0, list.length(models) - 1)
}

fn item_at(items: List(a), index: Int) -> Result(a, Nil) {
  items
  |> list.drop(index)
  |> list.first
}

fn drop_last_grapheme(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.concat
}
