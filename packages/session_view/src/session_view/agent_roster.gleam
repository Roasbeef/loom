//// The roster of live agents: which strands an agent strip lists, in what
//// order, and the words and figures each shows.
////
//// The terminal's strip and the web view's agent chips answer the same
//// question, "what is everybody doing right now", so they read one rule.
//// This module is that rule and the memory it needs between captures. How a
//// host draws a line, and how its keyboard or pointer moves between them,
//// stays with the host (`tui/agent_strip` draws terminal rows).
////
//// Each line joins two observations of the same capture. `agent_view.Row`
//// supplies the status and a deterministic activity line from the captured
//// operation and its running tools. The daemon's glance loop supplies a
//// model-written title and one-line summary in `client/glance/{strand}`
//// (`core/glance`). A glance is shown only while the operation it describes
//// is still the strand's current one, so a successor never wears its
//// predecessor's summary; until the first glance arrives, the line falls
//// back to the deterministic activity rather than showing nothing.
////
//// Time and tokens are the two figures that need care. A host never
//// subtracts a server timestamp from its own clock, so elapsed time is
//// anchored twice over: locally when the host first sees an operation, and
//// re-anchored to the daemon's own `glance.at - started_at` whenever a new
//// glance arrives, which keeps a reattached client from claiming a
//// thirty-minute agent started five seconds ago. Tokens are the context size
//// of the operation's newest generation, from a live usage push when the
//// host has seen one and from the glance otherwise.

import core/glance.{type Glance}
import core/message
import core/register
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec
import session_view/agent_view
import session_view/snapshot_view
import session_view/strand_name
import session_view/text_hygiene

/// The advisor's strand identity. A strip draws it in a band of its own,
/// never among the working agents.
pub const advisor = "advisor"

/// The primary strand's identity, which always leads a strip.
pub const primary = "main"

/// Anchors one operation's elapsed time without mixing clocks.
///
/// `offset_ms` is a duration the daemon measured on its own clock, and
/// `anchor_ms` is the host's clock when that duration was observed, so the
/// elapsed time is `offset_ms + (now - anchor_ms)`: each subtraction stays
/// on one clock.
pub type Clock {
  Clock(
    /// The operation this clock times; a successor starts a new clock.
    operation: String,
    /// The glance write the offset came from, when there was one.
    glance_at: Option(Int),
    /// Daemon-measured time the operation had run when anchored.
    offset_ms: Int,
    /// Host-clock instant the offset was observed.
    anchor_ms: Int,
  )
}

/// Everything the roster remembers between captures.
pub type Roster {
  Roster(
    /// Decoded glances from the latest capture, keyed by strand.
    glances: Dict(String, Glance),
    /// Elapsed-time anchors for each strand's current operation.
    clocks: Dict(String, Clock),
    /// Context size from live usage pushes, keyed by strand and tagged with
    /// the operation it belongs to.
    pushed: Dict(String, #(String, Int)),
    /// The host clock as of the last tick, so drawing reads no clock.
    now_ms: Int,
  )
}

/// One listed agent: its identity, state, words and figures.
pub type Line {
  Line(
    /// Stable strand identity, used for a cursor and for opening.
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

/// Whether a tick moved anything a strip draws.
pub type Repaint {
  /// A drawn figure changed; the frame must be rebuilt.
  Changed

  /// Nothing drawn changed; the cached frame stays valid.
  Unchanged
}

/// A strip laid out as chips: the listed agents, the advisor in its own
/// place, and the settled strands that left the listed ones.
pub type Chips {
  Chips(
    /// `main` first, then every other strand whose state needs watching,
    /// in roster order (`lines`).
    listed: List(Line),
    /// The advisor, when the capture holds its strand.
    advisor: Option(Line),
    /// Strands that are neither listed nor the advisor: settled work, in
    /// reverse row order. Rows keep the order strands were first seen, so a
    /// strand seen to join while the page was open comes before the strands
    /// that were present at the first capture, and those follow the store's
    /// key order, reversed. Rows carry no join time, so this is not a recency
    /// order. A host draws as many as it has room for and counts the rest.
    settled: List(Line),
  )
}

/// A roster with nothing observed.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.new().now_ms == 0
/// ```
pub fn new() -> Roster {
  Roster(glances: dict.new(), clocks: dict.new(), pushed: dict.new(), now_ms: 0)
}

/// Folds one coherent capture into the roster's memory.
///
/// Glances are decoded once here rather than on every frame. A cell that does
/// not decode is skipped, which leaves that line on its deterministic
/// activity: a daemon from another build must not blank the strip. Clocks
/// and pushed usage survive only for operations that are still current.
///
/// ## Examples
///
/// ```gleam
/// // agent_roster.observe(roster, view, now_ms)
/// ```
pub fn observe(
  roster: Roster,
  view: snapshot_view.View,
  now_ms: Int,
) -> Roster {
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
        dict.get(roster.clocks, strand)
        |> option.from_result
        |> keep_if(fn(clock) { clock.operation == operation })
      #(strand, next_clock(previous, operation, current, started, now_ms))
    })
    |> dict.from_list
  let pushed =
    dict.filter(roster.pushed, fn(strand, pair) {
      dict.get(view.operations, strand) == Ok(pair.0)
    })
  Roster(glances:, clocks:, pushed:, now_ms:)
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

// When an operation started, in the daemon's Unix milliseconds, from its
// metadata cell in a capture. The roster re-anchors its clocks on it and
// never hands it out: an instant from the daemon's clock means nothing
// against a host's.
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
/// host's clock.
///
/// ## Examples
///
/// ```gleam
/// let fresh = agent_roster.next_clock(None, "op", None, None, 500)
/// assert agent_roster.elapsed_ms(fresh, 2500) == 2000
/// ```
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
  // the host sees it a capture later, so the measurement is always a little
  // behind. Taking the larger of it and the running figure keeps the drawn
  // time from stepping backwards at each re-anchor.
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

/// The elapsed time a clock reports at a host-clock instant.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.elapsed_ms(agent_roster.Clock("op", None, 1000, 0), 500)
///   == 1500
/// ```
pub fn elapsed_ms(clock: Clock, now_ms: Int) -> Int {
  int.max(0, clock.offset_ms + now_ms - clock.anchor_ms)
}

/// Records a live usage push as the operation's current context size.
///
/// Pushes without an operation are dropped, since a figure the roster cannot
/// tie to the current task would be attributed to whichever task is running.
///
/// ## Examples
///
/// ```gleam
/// // agent_roster.observe_usage(roster, "sub:main/x", Some("op"), usage)
/// ```
pub fn observe_usage(
  roster: Roster,
  strand: String,
  operation: Option(String),
  context: Int,
) -> Roster {
  case operation {
    None -> roster
    Some(operation) ->
      Roster(
        ..roster,
        pushed: dict.insert(roster.pushed, strand, #(operation, context)),
      )
  }
}

/// The context a generation leaves an agent holding: everything it sent,
/// cached or not, plus what it wrote. This is the figure a usage push
/// records as the operation's context size (`observe_usage`).
///
/// ## Examples
///
/// ```gleam
/// // agent_roster.context(usage) == usage.input + usage.cache_read
/// //   + usage.cache_write + usage.output
/// ```
pub fn context(usage: message.Usage) -> Int {
  usage.input + usage.cache_read + usage.cache_write + usage.output
}

/// Advances the roster's clock. Reports whether a drawn second changed, so a
/// host repaints only when the figures a person can see actually moved.
///
/// ## Examples
///
/// ```gleam
/// let #(_, moved) = agent_roster.tick(agent_roster.new(), 0)
/// assert moved == agent_roster.Unchanged
/// ```
pub fn tick(roster: Roster, now_ms: Int) -> #(Roster, Repaint) {
  let clocks = dict.values(roster.clocks)
  let seconds = fn(at) {
    list.map(clocks, fn(clock) { elapsed_ms(clock, at) / 1000 })
  }
  let advanced = Roster(..roster, now_ms:)
  case seconds(roster.now_ms) == seconds(now_ms) {
    True -> #(advanced, Unchanged)
    False -> #(advanced, Changed)
  }
}

/// Projects the lines a strip draws, in stable roster order.
///
/// `main` always leads, since it is the way back to the primary. After it
/// come the active strand and every strand whose state needs watching:
/// working, waiting, needing input or halted, and a strand that has never run
/// an operation, which is idle because it waits for its first prompt (a fresh
/// fork). Settled strands leave the strip; the workspace keeps their
/// outcomes. The advisor has its own band
/// and is listed only while it is the active strand.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.lines(agent_roster.new(), [], "main") == []
/// ```
pub fn lines(
  roster: Roster,
  rows: List(agent_view.Row),
  active: String,
) -> List(Line) {
  let #(leading, others) = list.partition(rows, fn(row) { row.id == primary })
  list.append(leading, list.filter(others, listed(_, active)))
  |> list.map(line(roster, _))
}

/// Counts the rows a strip lists without formatting their text or figures.
///
/// Geometry depends only on membership. Reusing the listing predicate keeps
/// layout and painting in agreement without sanitizing every task on each
/// height query.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.listed_count([], "main") == 0
/// ```
@internal
pub fn listed_count(rows: List(agent_view.Row), active: String) -> Int {
  list.count(rows, fn(row) { row.id == primary || listed(row, active) })
}

/// The strip as chips: `lines` for everything but the advisor, the advisor
/// on its own, and the strands that settled out of the strip, in reverse row order.
///
/// The listed lines are exactly `lines`' when the advisor is not the active
/// strand; when it is, it is not listed twice.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.chips(agent_roster.new(), [], "main")
///   == agent_roster.Chips([], None, [])
/// ```
pub fn chips(
  roster: Roster,
  rows: List(agent_view.Row),
  active: String,
) -> Chips {
  let listed =
    lines(roster, rows, active)
    |> list.filter(fn(line) { line.id != advisor })
  let advisor_line =
    rows
    |> list.find(fn(row) { row.id == advisor })
    |> result.map(line(roster, _))
    |> option.from_result
  let settled =
    rows
    |> list.filter(fn(row) {
      row.id != advisor && !list.any(listed, fn(line) { line.id == row.id })
    })
    |> list.reverse
    |> list.map(line(roster, _))
  Chips(listed:, advisor: advisor_line, settled:)
}

fn listed(row: agent_view.Row, active: String) -> Bool {
  case row.id == active, row.id, row.status {
    True, _, _ -> True
    False, "advisor", _ -> False
    False, _, agent_view.Idle if row.operation == None -> True
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

/// One agent's line whether or not a strip would list it.
///
/// `lines` lists only the agents worth watching; a host that shows every
/// agent, as the terminal's workspace list does, describes the rest with
/// the same words and figures through this.
///
/// ## Examples
///
/// ```gleam
/// // agent_roster.describe(roster, finished_row).status == agent_view.Finished
/// ```
pub fn describe(roster: Roster, row: agent_view.Row) -> Line {
  line(roster, row)
}

fn line(roster: Roster, row: agent_view.Row) -> Line {
  let current = case row.operation {
    Some(operation) -> current_glance(roster.glances, row.id, operation)
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
  let pushed =
    row.operation
    |> option.then(fn(operation) {
      dict.get(roster.pushed, row.id)
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
    elapsed_s: option.map(running_ms(roster, row), fn(ms) { ms / 1000 }),
    tokens:,
  )
}

/// How long a strand's current operation has run, in milliseconds as of
/// the roster's last tick, or `None` when the row has no operation or the
/// roster no clock for it.
///
/// The figure is a duration on the host's own clock, so a host that counts
/// on from it somewhere else (the browser, for the web view's chips) anchors
/// it to that clock when it arrives and never meets the daemon's.
///
/// ## Examples
///
/// ```gleam
/// // agent_roster.running_ms(roster, row) == Some(4500)
/// ```
pub fn running_ms(roster: Roster, row: agent_view.Row) -> Option(Int) {
  row.operation
  |> option.then(fn(operation) {
    dict.get(roster.clocks, row.id)
    |> option.from_result
    |> keep_if(fn(clock) { clock.operation == operation })
  })
  |> option.map(elapsed_ms(_, roster.now_ms))
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
/// assert agent_roster.short_name("sub:main/audit-panics-1a2b3c") == "audit-panics"
/// assert agent_roster.short_name("main") == "main"
/// ```
pub fn short_name(name: String) -> String {
  strand_name.short(name)
}

// The deterministic activity names other strands by their minted IDs, as
// in `Waiting for sub:main/audit-1a2b…, sub:main/review-3c4d…`. On a line
// that is the person's glance, each ID is cut to the slug the strip already
// shows as that agent's name, so the waits read as names.
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

/// Whether a strip is drawn: only when there is a second agent to watch.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.visible([]) == False
/// ```
pub fn visible(lines: List(Line)) -> Bool {
  case lines {
    [_, _, ..] -> True
    [] | [_] -> False
  }
}

/// The composer badge naming the viewed agent's task, when it has one.
///
/// The primary gets no badge: its task is the conversation on screen.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.badge([], "main") == None
/// ```
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

/// Formats an elapsed duration the way a strip shows it.
///
/// ## Examples
///
/// ```gleam
/// assert agent_roster.duration(7) == "7s"
/// assert agent_roster.duration(475) == "7m 55s"
/// assert agent_roster.duration(3720) == "1h 02m"
/// ```
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
/// assert agent_roster.count_label(950) == "950"
/// assert agent_roster.count_label(136_540) == "136.5k"
/// assert agent_roster.count_label(2_300_000) == "2.3m"
/// ```
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
