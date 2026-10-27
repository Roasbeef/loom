//// A scripted host for the loop tests: a world in which a candidate's
//// quality is a pure function of its components, the reflector answers
//// from a script, and every evaluation charges what the test says.
////
//// The world drives the real `gepa.next`/`gepa.apply` loop the way a host
//// would, so the properties the tests hold (spend never past the budget,
//// the confirm always paid for, replay exact, resume from any prefix
//// identical) are properties of the library and the loop together, not
//// of a mock of either.

import gepa.{type Config, type Event, type State}
import gepa/budget
import gepa/log
import gepa/prompt
import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// How an evaluation charges against its cap.
pub type Charge {
  /// Exactly its worst case, as the search reserved it.
  WorstCase

  /// Twice its worst case, cut at its cap: a run whose cells retried past
  /// the estimate, which only the cap stops.
  Greedy

  /// Thirty times its worst case and no cap at all: a host that ignores
  /// what it was handed, which the search can only survive by refusing
  /// what it can no longer cover.
  Unbounded
}

/// The scripted host.
pub type World {
  World(
    /// How evaluations charge.
    charge: Charge,
    /// The reflector's answer at each step; a step past the script
    /// answers a text that changes nothing. A step of several proposals
    /// reads its answer as `|`-separated pieces, one per proposal, the
    /// last piece varied by number when there are fewer pieces.
    answers: List(#(Int, String)),
  )
}

/// A world whose reflector answers "better" at step 1 and nothing new
/// after, charging the worst case.
///
/// ## Examples
///
/// ```gleam
/// let world = world.planted()
/// ```
///
pub fn planted() -> World {
  World(charge: WorstCase, answers: [#(1, "better")])
}

/// A candidate's score on a task: one when any component says "even
/// better", three quarters when one says "better", else zero. The middle
/// grade exists so a found improvement is not at the ceiling, where the
/// search would rightly skip reflecting on it.
///
/// ## Examples
///
/// ```gleam
/// assert world.quality([#("a", "be better")]) == 0.75
/// ```
///
pub fn quality(components: List(#(String, String))) -> Float {
  let says = fn(word) {
    list.any(components, fn(c) { string.contains(c.1, word) })
  }

  // The best word wins; a candidate that says neither scores nothing.
  case says("even better"), says("better") {
    True, _ -> 1.0
    False, True -> 0.75
    False, False -> 0.0
  }
}

/// Drives the loop to `Done`, returning the final state and every event
/// applied, oldest first, including the seed row.
///
/// ## Examples
///
/// ```gleam
/// let #(state, events) = world.drive(gepa.start("s", []), [gepa.Seeded("s", [])], config, world)
/// ```
///
pub fn drive(
  state: State,
  events: List(Event),
  config: Config,
  world: World,
) -> #(State, List(Event)) {
  let assert Ok(request) = gepa.next(state, config)
    as "the scripted world's configuration is runnable"

  // Each request is performed in the world and its event fed back.
  case request {
    gepa.Done -> #(state, events)

    gepa.Record(event:) -> step(state, events, config, world, event)

    gepa.Evaluate(stage:, step: at, candidate:, tasks:, trials:, cap:) -> {
      let worst =
        budget.cell_worst_case(config.costs)
        *. int.to_float(list.length(tasks) * trials)
      let both = case stage {
        gepa.Confirm -> [state.seed, candidate]
        _ -> [candidate]
      }
      let measured =
        list.map(both, fn(id) {
          let assert Ok(member) =
            list.find(state.members, fn(m) { m.candidate == id })
            as "an evaluated candidate is a member"
          gepa.Measured(
            candidate: id,
            scores: list.map(tasks, fn(task) {
              gepa.Score(
                task:,
                value: quality(member.components),
                feedback: "ran",
              )
            }),
          )
        })
      let cost = case world.charge {
        WorstCase -> float.min(cap, worst *. int.to_float(list.length(both)))
        Greedy ->
          float.min(cap, 2.0 *. worst *. int.to_float(list.length(both)))
        Unbounded -> 30.0 *. worst *. int.to_float(list.length(both))
      }

      step(
        state,
        events,
        config,
        world,
        gepa.Evaluated(
          stage:,
          step: at,
          candidate:,
          tasks:,
          cap:,
          ref: "run-" <> int.to_string(list.length(events)),
          measured:,
          cost:,
        ),
      )
    }

    gepa.Reflect(step: at, slot:, worst_case:, proposal:, of:, ..) -> {
      let text =
        list.key_find(world.answers, at)
        |> result_or("same " <> int.to_string(at))
        |> variant(proposal)
      let reflected =
        gepa.Reflected(at, worst_case, "", gepa.Complete, proposal, of)
      let state_after = apply(state, reflected)
      let assert Ok(admitted) =
        gepa.admit(state_after, slot, prompt.answer(text), gepa.content_id)
        as "an open step admits an answer"

      step(
        state_after,
        list.append(events, [reflected]),
        config,
        world,
        admitted,
      )
    }
  }
}

/// The answer for one proposal of a step: a scripted answer is split on
/// `|`, the proposal's piece if the script has one, else the last piece
/// marked with the proposal's number so siblings differ.
fn variant(text: String, proposal: Int) -> String {
  let pieces = string.split(text, "|")

  // The script names the piece, or the last piece is varied.
  case list.drop(pieces, proposal - 1) {
    [piece, ..] -> piece
    [] -> result_or(list.last(pieces), "") <> " v" <> int.to_string(proposal)
  }
}

fn result_or(found: Result(String, Nil), fallback: String) -> String {
  case found {
    Ok(text) -> text
    Error(Nil) -> fallback
  }
}

/// Applies one event and carries on driving.
fn step(
  state: State,
  events: List(Event),
  config: Config,
  world: World,
  event: Event,
) -> #(State, List(Event)) {
  drive(apply(state, event), list.append(events, [event]), config, world)
}

fn apply(state: State, event: Event) -> State {
  let assert Ok(next) = gepa.apply(state, event)
    as "the loop never feeds back an event the fold refuses"
  next
}

/// Runs a whole search from a seed in the world.
///
/// ## Examples
///
/// ```gleam
/// let #(state, events) = world.search(config, world.planted())
/// ```
///
pub fn search(config: Config, world: World) -> #(State, List(Event)) {
  let seeded = gepa.Seeded("seed", [#("a", "plain"), #("b", "")])
  drive(
    gepa.start("seed", [#("a", "plain"), #("b", "")]),
    [seeded],
    config,
    world,
  )
}

/// The log of a search as text.
///
/// ## Examples
///
/// ```gleam
/// let text = world.log_of(events)
/// ```
///
pub fn log_of(events: List(Event)) -> String {
  log.render(events)
}
