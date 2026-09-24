//// The agent strip: one row per live agent, pinned under the footer, so an
//// operator running several strands at once can see what each is doing
//// without opening anything.
////
//// The `/agents` workspace answers every question about a strand, but only
//// once the operator goes looking. The strip answers the one question asked
//// most often, "what is everybody doing right now", from the corner of the
//// eye. It grows by a row as each agent starts, and drops a row when an agent
//// settles, so its height is itself a count of the work in flight.
////
//// Each row joins two observations of the same capture. `agent_view.Row`
//// supplies the status and a deterministic activity line from the captured
//// operation and its running tools. The daemon's glance loop supplies a
//// model-written title and one-line summary in `client/glance/{strand}`
//// (`core/glance`). A glance is shown only while the operation it describes
//// is still the strand's current one, so a successor never wears its
//// predecessor's summary; until the first glance arrives, the row falls back
//// to the deterministic line rather than showing nothing.
////
//// Time and tokens are the two figures that need care. The terminal never
//// subtracts a server timestamp from its own clock, so elapsed time is
//// anchored twice over: locally when the terminal first sees an operation,
//// and re-anchored to the daemon's own `glance.at - started_at` whenever a
//// new glance arrives, which keeps a reattached terminal from claiming a
//// thirty-minute agent started five seconds ago. Tokens are the context size
//// of the operation's newest generation, from a live usage push when this
//// terminal has seen one and from the glance otherwise.
////
//// Keyboard focus is a separate small state machine. Down from an idle
//// composer moves a cursor into the strip; Up and Down move it; Enter opens
//// the selected strand (the transcript and the composer's recipient switch
//// together, through the same path the workspace's Enter uses); `x` stops
//// the selected strand's operation; Escape, or Up past the first row, hands
//// the keyboard back. Moving the cursor never retargets the composer, so an
//// unsent draft can never be redirected to an agent by browsing.

import core/glance.{type Glance}
import core/register
import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/text
import etui/widgets/paragraph
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec
import tui/agent_view
import tui/agents
import tui/snapshot_view
import tui/text_hygiene
import tui/theme

/// The most agent rows the strip draws before it folds the rest into a count.
@internal
pub const max_rows = 8

/// The shortest terminal the strip appears on. Below this the transcript and
/// editor keep every row, and the footer's agent count remains the summary.
@internal
pub const min_screen_height = 16

/// Who owns the keyboard: the composer, or the strip with its cursor on one
/// strand. The cursor is a strand ID rather than an index, so a row arriving
/// or leaving above it cannot move the selection to a different agent.
@internal
pub type Focus {
  /// The composer has the keyboard; the strip only displays.
  Composing

  /// The strip has the keyboard and the cursor rests on `cursor`.
  Browsing(cursor: String)
}

/// Anchors one operation's elapsed time without mixing clocks.
///
/// `offset_ms` is a duration the daemon measured on its own clock, and
/// `anchor_ms` is the terminal's clock when that duration was observed, so
/// the elapsed time is `offset_ms + (now - anchor_ms)`: each subtraction
/// stays on one clock.
@internal
pub type Clock {
  Clock(
    /// The operation this clock times; a successor starts a new clock.
    operation: String,
    /// The glance write the offset came from, when there was one.
    glance_at: Option(Int),
    /// Daemon-measured time the operation had run when anchored.
    offset_ms: Int,
    /// Terminal-clock instant the offset was observed.
    anchor_ms: Int,
  )
}

/// Everything the strip remembers between captures.
@internal
pub type State {
  State(
    /// Keyboard ownership and the cursor.
    focus: Focus,
    /// Decoded glances from the latest capture, keyed by strand.
    glances: Dict(String, Glance),
    /// Elapsed-time anchors for each strand's current operation.
    clocks: Dict(String, Clock),
    /// Context size from live usage pushes, keyed by strand and tagged with
    /// the operation it belongs to.
    pushed: Dict(String, #(String, Int)),
    /// The terminal clock as of the last tick, so rendering reads no clock.
    now_ms: Int,
  )
}

/// One drawn row: an agent's identity, state, words and figures.
@internal
pub type Line {
  Line(
    /// Stable strand identity, used for the cursor and for opening.
    id: String,
    /// Short display name.
    name: String,
    /// Status justified by the capture.
    status: agent_view.Status,
    /// The glance summary when current, else the deterministic activity.
    text: String,
    /// The glance title when current, else the accepted task excerpt.
    title: String,
    /// Elapsed seconds of the current operation, when it has one.
    elapsed_s: Option(Int),
    /// Context size of the current operation, when known.
    tokens: Option(Int),
  )
}

/// What a key pressed while the strip has focus asks for.
@internal
pub type Outcome {
  /// The cursor moved, or nothing changed; the strip keeps the keyboard.
  Moved(State)

  /// The keyboard returns to the composer and the key is consumed.
  Left(State)

  /// Open this strand: switch the transcript and the composer's recipient.
  Open(State, strand: String)

  /// Stop this strand's running operation.
  Stop(State, strand: String)

  /// The keyboard returns to the composer, which should handle this key.
  Pass(State)
}

/// A strip with nothing observed and the composer holding the keyboard.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.new().focus == agent_strip.Composing
/// ```
@internal
pub fn new() -> State {
  State(
    focus: Composing,
    glances: dict.new(),
    clocks: dict.new(),
    pushed: dict.new(),
    now_ms: 0,
  )
}

/// Folds one coherent capture into the strip's memory.
///
/// Glances are decoded once here rather than on every frame. A cell that does
/// not decode is skipped, which leaves that row on its deterministic line:
/// a daemon from another build must not blank the strip. Clocks and pushed
/// usage survive only for operations that are still current.
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.observe(state, view, model.monotonic_time_ms())
/// ```
@internal
pub fn observe(state: State, view: snapshot_view.View, now_ms: Int) -> State {
  let glances =
    view.cells
    |> list.filter_map(fn(cell) {
      use strand <- result.try(glance_strand(cell))
      use decoded <- result.map(
        glance.decode(cell.value) |> result.replace_error(Nil),
      )
      #(strand, decoded)
    })
    |> dict.from_list

  // Each strand with a current operation gets a clock. The previous clock
  // carries over only for the same operation, and a newer glance re-anchors
  // it to the daemon's own measurement.
  let clocks =
    view.operations
    |> dict.to_list
    |> list.map(fn(pair) {
      let #(strand, operation) = pair
      let current = current_glance(glances, strand, operation)
      let started = started_at(view.cells, operation)
      let previous =
        dict.get(state.clocks, strand)
        |> option.from_result
        |> keep_if(fn(clock) { clock.operation == operation })
      #(strand, next_clock(previous, operation, current, started, now_ms))
    })
    |> dict.from_list
  let pushed =
    dict.filter(state.pushed, fn(strand, pair) {
      dict.get(view.operations, strand) == Ok(pair.0)
    })
  State(..state, glances:, clocks:, pushed:, now_ms:)
}

fn glance_strand(cell: snapshot_view.Cell) -> Result(String, Nil) {
  case cell.namespace == register.FactCustom {
    True -> glance.strand_of(cell.key)
    False -> Error(Nil)
  }
}

fn current_glance(
  glances: Dict(String, Glance),
  strand: String,
  operation: String,
) -> Option(Glance) {
  dict.get(glances, strand)
  |> option.from_result
  |> keep_if(fn(seen) { seen.operation == operation })
}

fn started_at(
  cells: List(snapshot_view.Cell),
  operation: String,
) -> Option(Int) {
  cells
  |> list.find(fn(cell) {
    cell.namespace == register.OpMeta && cell.key == operation
  })
  |> result.try(fn(cell) {
    codec.decode_operation(cell.value) |> result.replace_error(Nil)
  })
  |> result.map(fn(meta) { meta.started_at })
  |> option.from_result
}

/// Chooses the clock for a strand's current operation.
///
/// A glance the clock has not yet anchored to replaces the anchor with the
/// daemon's measured run time, since that stays right across a reattach. An
/// operation seen for the first time without one starts at zero on the
/// terminal's clock.
///
/// ## Examples
///
/// ```gleam
/// let fresh = agent_strip.next_clock(None, "op", None, None, 500)
/// assert agent_strip.elapsed_ms(fresh, 2500) == 2000
/// ```
@internal
pub fn next_clock(
  previous: Option(Clock),
  operation: String,
  current: Option(Glance),
  started: Option(Int),
  now_ms: Int,
) -> Clock {
  let kept = option.unwrap(previous, Clock(operation, None, 0, now_ms))
  let anchored = option.map(current, fn(seen) { seen.at })

  // The daemon measured `seen.at - started` when it wrote the glance, and
  // the terminal sees it a capture later, so the measurement is always a
  // little behind. Taking the larger of it and the running figure keeps the
  // drawn time from stepping backwards at each re-anchor.
  case current, started {
    Some(seen), Some(started) if kept.glance_at != anchored ->
      Clock(
        operation,
        anchored,
        int.max(seen.at - started, elapsed_ms(kept, now_ms)),
        now_ms,
      )
    _, _ -> kept
  }
}

/// The elapsed time a clock reports at a terminal-clock instant.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.elapsed_ms(agent_strip.Clock("op", None, 1000, 0), 500)
///   == 1500
/// ```
@internal
pub fn elapsed_ms(clock: Clock, now_ms: Int) -> Int {
  int.max(0, clock.offset_ms + now_ms - clock.anchor_ms)
}

/// Records a live usage push as the operation's current context size.
///
/// Pushes without an operation are dropped, since a figure the strip cannot
/// tie to the current task would be attributed to whichever task is running.
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.observe_usage(state, "sub:main/x", Some("op"), usage)
/// ```
@internal
pub fn observe_usage(
  state: State,
  strand: String,
  operation: Option(String),
  context: Int,
) -> State {
  case operation {
    None -> state
    Some(operation) ->
      State(
        ..state,
        pushed: dict.insert(state.pushed, strand, #(operation, context)),
      )
  }
}

/// Advances the strip's clock on the tick. Reports whether a drawn second
/// changed, so the tick repaints only when the figures the operator can see
/// actually moved.
///
/// ## Examples
///
/// ```gleam
/// let #(_, moved) = agent_strip.tick(agent_strip.new(), 0)
/// assert moved == agent_strip.Unchanged
/// ```
@internal
pub fn tick(state: State, now_ms: Int) -> #(State, Repaint) {
  let clocks = dict.values(state.clocks)
  let seconds = fn(at) {
    list.map(clocks, fn(clock) { elapsed_ms(clock, at) / 1000 })
  }
  let advanced = State(..state, now_ms:)
  case seconds(state.now_ms) == seconds(now_ms) {
    True -> #(advanced, Unchanged)
    False -> #(advanced, Changed)
  }
}

/// Whether a tick moved anything the strip draws.
@internal
pub type Repaint {
  /// A drawn figure changed; the frame must be rebuilt.
  Changed

  /// Nothing drawn changed; the cached frame stays valid.
  Unchanged
}

/// Projects the rows the strip draws, in stable roster order.
///
/// `main` always leads, since it is the way back to the primary. After it
/// come the active strand and every strand whose state needs watching:
/// working, waiting, needing input or halted. Settled strands leave the
/// strip; the workspace keeps their outcomes. The advisor has its own band
/// and is listed only while it is the active strand.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.lines(agent_strip.new(), [], "main") == []
/// ```
@internal
pub fn lines(
  state: State,
  rows: List(agent_view.Row),
  active: String,
) -> List(Line) {
  let #(primary, others) = list.partition(rows, fn(row) { row.id == "main" })
  list.append(primary, list.filter(others, listed(_, active)))
  |> list.map(line(state, _))
}

fn listed(row: agent_view.Row, active: String) -> Bool {
  case row.id == active, row.id, row.status {
    True, _, _ -> True
    False, "advisor", _ -> False
    False, _, agent_view.Working
    | False, _, agent_view.Waiting
    | False, _, agent_view.NeedsInput
    | False, _, agent_view.Halted
    -> True
    False, _, agent_view.Finished
    | False, _, agent_view.Failed
    | False, _, agent_view.Idle
    | False, _, agent_view.Unavailable
    -> False
  }
}

fn line(state: State, row: agent_view.Row) -> Line {
  let current = case row.operation {
    Some(operation) -> current_glance(state.glances, row.id, operation)
    None -> None
  }

  // A glance still waiting for its first summary has a title but no line,
  // and an empty row reads as a stall; the deterministic activity stands in.
  let text = case current {
    Some(seen) if seen.summary != "" -> seen.summary
    Some(_) | None -> shorten_names(row.activity)
  }
  let title = case current {
    Some(seen) if seen.title != "" -> seen.title
    Some(_) | None -> row.task
  }
  let clock =
    row.operation
    |> option.then(fn(operation) {
      dict.get(state.clocks, row.id)
      |> option.from_result
      |> keep_if(fn(clock) { clock.operation == operation })
    })
  let pushed =
    row.operation
    |> option.then(fn(operation) {
      dict.get(state.pushed, row.id)
      |> option.from_result
      |> keep_if(fn(pair) { pair.0 == operation })
      |> option.map(fn(pair) { pair.1 })
    })
  let tokens =
    option.lazy_or(pushed, fn() {
      option.map(current, fn(seen) { seen.tokens })
    })
    |> keep_if(fn(count) { count > 0 })
  Line(
    id: row.id,
    name: short_name(row.name),
    status: row.status,
    text: text_hygiene.single_line(text),
    title: text_hygiene.single_line(title),
    elapsed_s: option.map(clock, fn(clock) {
      elapsed_ms(clock, state.now_ms) / 1000
    }),
    tokens:,
  )
}

/// Shortens a minted child name to the words its parent chose.
///
/// A sub-agent is named `sub:{parent}/{slug}-{digest}`. The parent and the
/// digest disambiguate for the machine; the slug is what a person reads.
/// Anything not in that shape is returned whole.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.short_name("sub:main/audit-panics-1a2b3c") == "audit-panics"
/// assert agent_strip.short_name("main") == "main"
/// ```
@internal
pub fn short_name(name: String) -> String {
  case string.starts_with(name, "sub:") {
    False -> name
    True -> {
      let leaf =
        string.split(name, "/")
        |> list.last
        |> result.unwrap(name)
      case string.split(leaf, "-") |> list.reverse {
        [digest, first, ..rest] ->
          case is_digest(digest) {
            True -> [first, ..rest] |> list.reverse |> string.join("-")
            False -> leaf
          }
        [_] | [] -> leaf
      }
    }
  }
}

// The deterministic activity names other strands by their minted IDs, as
// in `Waiting for sub:main/audit-1a2b…, sub:main/review-3c4d…`. On a row
// that is the operator's glance, each ID is cut to the slug the strip
// already shows as that agent's name, so the waits read as names.
fn shorten_names(text: String) -> String {
  text
  |> string.split(" ")
  |> list.map(fn(word) {
    case string.starts_with(word, "sub:"), string.ends_with(word, ",") {
      False, _ -> word
      True, True -> short_name(string.drop_end(word, 1)) <> ","
      True, False -> short_name(word)
    }
  })
  |> string.join(" ")
}

fn is_digest(value: String) -> Bool {
  string.drop_start(value, 3) != ""
  && string.to_graphemes(value)
  |> list.all(fn(char) { string.contains("0123456789abcdef", char) })
}

/// Whether the strip is drawn: only when there is a second agent to watch.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.visible([]) == False
/// ```
@internal
pub fn visible(lines: List(Line)) -> Bool {
  case lines {
    [_, _, ..] -> True
    [] | [_] -> False
  }
}

/// The rows the strip takes on a screen, including its overflow row.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.height([], 40) == 0
/// ```
@internal
pub fn height(lines: List(Line), screen_height: Int) -> Int {
  case visible(lines) && screen_height >= min_screen_height {
    False -> 0
    True -> int.min(list.length(lines), capacity(screen_height))
  }
}

// A quarter of the screen, between two rows and `max_rows`, so a burst of
// agents cannot push the transcript off a small terminal.
fn capacity(screen_height: Int) -> Int {
  int.clamp(screen_height / 4, min: 2, max: max_rows)
}

/// Moves the keyboard into the strip, with the cursor on the row after the
/// strand being viewed, which is the agent a Down press most plausibly means.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.enter(agent_strip.new(), [], "main").focus
///   == agent_strip.Composing
/// ```
@internal
pub fn enter(state: State, lines: List(Line), active: String) -> State {
  let ids = list.map(lines, fn(line) { line.id })
  let after =
    ids
    |> list.drop_while(fn(id) { id != active })
    |> list.drop(1)
    |> list.first
  case after, ids {
    Ok(id), _ | Error(Nil), [id, ..] -> State(..state, focus: Browsing(id))
    Error(Nil), [] -> state
  }
}

/// Hands the keyboard back to the composer, keeping everything observed.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.leave(agent_strip.new()).focus == agent_strip.Composing
/// ```
@internal
pub fn leave(state: State) -> State {
  State(..state, focus: Composing)
}

/// Answers one key while the strip holds the keyboard.
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.key(state, keys.Enter, lines)
/// ```
@internal
pub fn key(state: State, pressed: StripKey, lines: List(Line)) -> Outcome {
  case state.focus {
    Composing -> Pass(state)
    Browsing(cursor) -> browse(state, pressed, lines, cursor)
  }
}

/// The keys the strip distinguishes; everything else hands back the keyboard.
@internal
pub type StripKey {
  /// Moves the cursor toward the top, or out of the strip from its top row.
  Up

  /// Moves the cursor toward the bottom.
  Down

  /// Opens the strand under the cursor.
  Select

  /// Stops the operation of the strand under the cursor.
  Halt

  /// Returns the keyboard to the composer.
  Back

  /// Any other key: returned to the composer to handle.
  Other
}

fn browse(
  state: State,
  pressed: StripKey,
  lines: List(Line),
  cursor: String,
) -> Outcome {
  let ids = list.map(lines, fn(line) { line.id })
  let composing = State(..state, focus: Composing)

  // A cursor whose strand has left the strip is re-seated on the first row
  // rather than acting on an agent the operator can no longer see.
  let cursor = case list.contains(ids, cursor), ids {
    True, _ -> Ok(cursor)
    False, [first, ..] -> Ok(first)
    False, [] -> Error(Nil)
  }
  case cursor, pressed {
    Error(Nil), _ -> Left(composing)
    Ok(_), Back -> Left(composing)
    Ok(_), Other -> Pass(composing)
    Ok(id), Select -> Open(composing, id)
    Ok(id), Halt -> Stop(State(..state, focus: Browsing(id)), id)
    Ok(id), Down -> Moved(State(..state, focus: Browsing(step(ids, id, 1))))
    Ok(id), Up ->
      case list.first(ids) == Ok(id) {
        True -> Left(composing)
        False -> Moved(State(..state, focus: Browsing(step(ids, id, -1))))
      }
  }
}

fn step(ids: List(String), from: String, by: Int) -> String {
  let indexed = list.index_map(ids, fn(id, index) { #(index, id) })
  let at =
    list.find(indexed, fn(pair) { pair.1 == from })
    |> result.map(fn(pair) { pair.0 })
    |> result.unwrap(0)
  let target = int.clamp(at + by, min: 0, max: list.length(ids) - 1)
  list.find(indexed, fn(pair) { pair.0 == target })
  |> result.map(fn(pair) { pair.1 })
  |> result.unwrap(from)
}

/// The composer badge naming the viewed agent's task, when it has one.
///
/// The primary gets no badge: its task is the conversation on screen.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.badge([], "main") == None
/// ```
@internal
pub fn badge(lines: List(Line), active: String) -> Option(String) {
  case active {
    "main" -> None
    _ ->
      lines
      |> list.find(fn(line) { line.id == active })
      |> option.from_result
      |> option.map(fn(line) { line.title })
      |> keep_if(fn(title) { title != "" })
  }
}

/// Paints the strip into its area, bottom-aligned under the footer.
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.render(buf, area, lines, state.focus, "main")
/// ```
@internal
pub fn render(
  buf: buffer.Buffer,
  area: Rect,
  lines: List(Line),
  focus: Focus,
  active: String,
) -> buffer.Buffer {
  let capacity = area.size.height
  let overflow = list.length(lines) - capacity
  let shown = case overflow > 0 {
    True -> window(lines, focus, capacity - 1)
    False -> lines
  }
  let rows =
    list.map(shown, fn(line) { row(line, focus, active, area.size.width) })
  let rows = case overflow > 0 {
    False -> rows
    True ->
      list.append(rows, [
        span.line_new([
          span.span_styled(
            text.pad_right(
              "  +"
                <> int.to_string(list.length(lines) - list.length(shown))
                <> " more · F2 agents",
              area.size.width,
            ),
            theme.quiet_text(),
          ),
        ]),
      ])
  }
  paragraph.render_styled(buf, area, rows)
}

// When the rows outnumber the space, the window follows the cursor so the
// selected agent is always drawn; otherwise it shows the top of the roster.
fn window(lines: List(Line), focus: Focus, size: Int) -> List(Line) {
  let at = case focus {
    Composing -> 0
    Browsing(cursor) ->
      list.index_map(lines, fn(line, index) { #(index, line.id) })
      |> list.find(fn(pair) { pair.1 == cursor })
      |> result.map(fn(pair) { pair.0 })
      |> result.unwrap(0)
  }
  let start = int.clamp(at - size + 1, min: 0, max: list.length(lines))
  lines |> list.drop(start) |> list.take(size)
}

fn row(line: Line, focus: Focus, active: String, width: Int) -> span.Line {
  let selected = focus == Browsing(line.id)
  let viewing = line.id == active
  let background = case selected {
    True -> theme.raised
    False -> style.Default
  }

  // The cursor and the viewed strand each carry a mark as well as a color,
  // so the strip still reads on a terminal with no color at all.
  let cursor = case selected, viewing {
    True, _ -> "❯ "
    False, True -> "› "
    False, False -> "  "
  }

  // The meter keeps its column; on a narrow terminal it goes first, since
  // what the agent is doing matters more than for how long.
  let meter = case width >= 72 {
    True -> meter(line)
    False -> ""
  }
  let name_width = int.min(22, int.max(8, width / 5))
  let name = text.pad_right(fit(line.name, name_width), name_width)
  let lead = cursor <> agents.status_mark(line.status) <> " "
  let room =
    width - text.cell_width(lead) - name_width - 1 - text.cell_width(meter) - 1
  let body = text.pad_right(fit(line.text, room), int.max(0, room))
  let name_style = case viewing {
    True -> style.new(theme.signal, background, style.bold())
    False -> style.new(theme.current, background, style.none())
  }
  span.line_new([
    span.span_styled(cursor, style.new(theme.signal, background, style.bold())),
    span.span_styled(
      agents.status_mark(line.status) <> " ",
      agents.status_style(line.status, background),
    ),
    span.span_styled(name <> " ", name_style),
    span.span_styled(
      body <> " ",
      style.new(theme.paper, background, style.none()),
    ),
    span.span_styled(meter, style.new(theme.quiet, background, style.none())),
  ])
}

fn meter(line: Line) -> String {
  let time = option.map(line.elapsed_s, duration)
  let size = option.map(line.tokens, fn(count) { count_label(count) <> " ctx" })
  case time, size {
    Some(time), Some(size) -> time <> " · " <> size
    Some(one), None | None, Some(one) -> one
    None, None -> ""
  }
}

/// Formats an elapsed duration the way the strip shows it.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.duration(7) == "7s"
/// assert agent_strip.duration(475) == "7m 55s"
/// assert agent_strip.duration(3720) == "1h 02m"
/// ```
@internal
pub fn duration(seconds: Int) -> String {
  case seconds >= 3600, seconds >= 60 {
    True, _ ->
      int.to_string(seconds / 3600)
      <> "h "
      <> pad2({ seconds % 3600 } / 60)
      <> "m"
    False, True ->
      int.to_string(seconds / 60) <> "m " <> pad2(seconds % 60) <> "s"
    False, False -> int.to_string(int.max(0, seconds)) <> "s"
  }
}

/// Abbreviates a token count with one decimal in the thousands, so a
/// strip watched for a minute shows movement rather than a frozen `136k`.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.count_label(950) == "950"
/// assert agent_strip.count_label(136_540) == "136.5k"
/// assert agent_strip.count_label(2_300_000) == "2.3m"
/// ```
@internal
pub fn count_label(value: Int) -> String {
  case value >= 1_000_000, value >= 1000 {
    True, _ -> tenths(value, 1_000_000) <> "m"
    False, True -> tenths(value, 1000) <> "k"
    False, False -> int.to_string(int.max(0, value))
  }
}

fn tenths(value: Int, unit: Int) -> String {
  let scaled = value * 10 / unit
  int.to_string(scaled / 10) <> "." <> int.to_string(scaled % 10)
}

fn pad2(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}

fn fit(value: String, width: Int) -> String {
  text.truncate(text_hygiene.single_line(value), int.max(0, width), "…")
}

// Keeps an optional value only while it still satisfies the predicate, the
// shape every "is this still about the current operation" check here takes.
fn keep_if(value: Option(a), predicate: fn(a) -> Bool) -> Option(a) {
  case value {
    Some(inner) ->
      case predicate(inner) {
        True -> value
        False -> None
      }
    None -> None
  }
}
