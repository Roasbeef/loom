//// Generation timing belongs to a strand, never to the view selecting it.
////
//// Every observed strand keeps its current request clock and latest measured
//// output rate. A focus change reads another entry without altering either.
//// Captures seed off-screen clocks too, but a first capture or fragment can
//// arrive halfway through a request: that clock can draw elapsed observation
//// time, while only an observed phase boundary permits a TPS calculation.
//// Settlements consume one clock, so repeated captures cannot time it twice.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import session_view/transcript_lines

/// Where the beginning of a generation was observed.
pub type Observation {
  /// A live phase transition names a request boundary.
  Transition

  /// A coherent capture may first reveal an already running request.
  Capture
}

/// Whether the output count and elapsed window cover the same request.
type Window {
  Whole
  Partial
}

type Clock {
  Clock(started: Int, window: Window)
}

type Reading {
  Reading(
    phase: String,
    clock: Option(Clock),
    generation: Option(String),
    rate: Option(Int),
  )
}

/// Session-scoped readings; only this module changes their lifecycle.
pub opaque type State {
  State(readings: Dict(String, Reading))
}

/// Starts with no clocks or rates.
///
/// ## Examples
///
/// ```gleam
/// assert generation_rate.rate(generation_rate.new(), "main") == None
/// ```
pub fn new() -> State {
  State(dict.new())
}

/// Observes a phase for any strand without consulting the selected view.
/// Repeated assistant observations preserve the original clock, including a
/// consumed clock. Done retires an unsettled clock without discarding its rate.
///
/// ## Examples
///
/// ```gleam
/// // generation_rate.phase(state, "worker", "assistant", Transition, now)
/// ```
pub fn phase(
  state: State,
  strand: String,
  phase: String,
  source: Observation,
  now: Int,
) -> State {
  let existing = dict.get(state.readings, strand)
  let old = result.unwrap(existing, Reading("", None, None, None))

  // Stream identity survives the view's active-only stream projection. Until
  // settlement consumes its clock, an older capture cannot insert a boundary
  // into that same request and upgrade a partial window to a complete one.
  let lagging = case source, old.clock, old.generation {
    Capture, Some(_), Some(_) -> phase != "assistant"
    _, _, _ -> False
  }
  let reading = case lagging, phase, old.phase {
    True, _, _ -> old

    False, "assistant", "assistant" -> old
    False, "assistant", _ -> {
      let window = case source, existing {
        Transition, _ | Capture, Ok(_) -> Whole
        Capture, Error(_) -> Partial
      }
      Reading(..old, phase:, clock: Some(Clock(now, window)), generation: None)
    }
    False, "done", _ -> Reading(..old, phase:, clock: None)
    False, _, _ -> Reading(..old, phase:)
  }
  State(dict.insert(state.readings, strand, reading))
}

/// A fragment can reveal a request whose phase was missed. Such a partial
/// window never divides the full output count. A new generation identity retires
/// an older clock; end markers and late fragments of a settled request do not
/// restart it.
///
/// ## Examples
///
/// ```gleam
/// // generation_rate.stream(state, "worker", "request-2", "text", now)
/// ```
pub fn stream(
  state: State,
  strand: String,
  generation: String,
  kind: String,
  now: Int,
) -> State {
  case kind {
    "end" -> state
    _ -> {
      let old = reading(state, strand)
      let next = case old.generation, old.clock {
        Some(previous), _ if previous == generation -> old
        None, Some(_) -> Reading(..old, generation: Some(generation))
        _, _ ->
          Reading(
            ..old,
            phase: "assistant",
            clock: Some(Clock(now, Partial)),
            generation: Some(generation),
          )
      }
      State(dict.insert(state.readings, strand, next))
    }
  }
}

/// Settles only this strand's request. A partial or absent clock preserves the
/// last measured rate; callers decline replay and disconnected measurements by
/// retiring their clocks with `untimed` instead.
///
/// ## Examples
///
/// ```gleam
/// // generation_rate.settle(state, "worker", 800, now)
/// ```
pub fn settle(state: State, strand: String, output: Int, now: Int) -> State {
  let old = reading(state, strand)
  let rate = case old.clock {
    Some(Clock(started, Whole)) ->
      transcript_lines.output_rate(output, now - started)
    Some(Clock(_, Partial)) | None -> old.rate
  }
  State(dict.insert(state.readings, strand, Reading(..old, clock: None, rate:)))
}

/// Retires one clock when elapsed time cannot measure provider work.
///
/// ## Examples
///
/// ```gleam
/// // generation_rate.untimed(state, "worker")
/// ```
pub fn untimed(state: State, strand: String) -> State {
  let old = reading(state, strand)
  State(dict.insert(state.readings, strand, Reading(..old, clock: None)))
}

/// Keeps only strands present in the authoritative roster, bounding retained
/// readings by the session's current strand set.
///
/// ## Examples
///
/// ```gleam
/// // generation_rate.retain(state, ["main", "worker"])
/// ```
pub fn retain(state: State, strands: List(String)) -> State {
  let known = set.from_list(strands)
  State(
    dict.filter(state.readings, fn(strand, _) { set.contains(known, strand) }),
  )
}

/// Reads the selected strand's observation clock, independently of its rate.
///
/// ## Examples
///
/// ```gleam
/// assert generation_rate.started(generation_rate.new(), "worker") == None
/// ```
pub fn started(state: State, strand: String) -> Option(Int) {
  option.map(reading(state, strand).clock, fn(clock) { clock.started })
}

/// Reads only this strand's latest complete measurement.
///
/// ## Examples
///
/// ```gleam
/// assert generation_rate.rate(generation_rate.new(), "worker") == None
/// ```
pub fn rate(state: State, strand: String) -> Option(Int) {
  reading(state, strand).rate
}

/// Sets an explicit clock for hosts and fixtures already holding its boundary.
///
/// ## Examples
///
/// ```gleam
/// // generation_rate.with_started(state, "main", Some(1000))
/// ```
@internal
pub fn with_started(
  state: State,
  strand: String,
  started: Option(Int),
) -> State {
  let old = reading(state, strand)
  State(dict.insert(
    state.readings,
    strand,
    Reading(..old, clock: option.map(started, fn(ms) { Clock(ms, Whole) })),
  ))
}

/// Sets an explicit settled reading without changing its request clock.
///
/// ## Examples
///
/// ```gleam
/// // generation_rate.with_rate(state, "main", Some(100))
/// ```
@internal
pub fn with_rate(state: State, strand: String, rate: Option(Int)) -> State {
  let old = reading(state, strand)
  State(dict.insert(state.readings, strand, Reading(..old, rate:)))
}

fn reading(state: State, strand: String) -> Reading {
  dict.get(state.readings, strand)
  |> result.unwrap(Reading("", None, None, None))
}
