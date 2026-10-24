//// The governed-evolution door, as a code-mode capability router.
////
//// Evolution reaches a model through one route: a program that imports
//// `cap/evolution`. This module is the harness half of that route. It maps
//// six capability names onto six closures the host built for one execution,
//// and it carries no authority of its own. Each closure was bound by the
//// host to the dispatching strand, operation and workspace, so a program
//// supplies arguments and never coordinates.
////
//// ## Flow
////
//// `routing` → `plan` → `answer`
////
//// 1. `routing` wraps an inner router and claims only the six names
////    listed in the serviced-capability constant. Every other capability
////    falls through untouched, so an evolution call can never shadow a
////    workspace one.
//// 2. `plan` converts the call's msgpack arguments into JSON, refusing the
////    two shapes JSON cannot carry (binary values and non-text keys), and
////    returns a `ServedHere` plan. The served closure runs on its own process
////    under the host's call timeout, never on the host actor.
//// 3. `answer` turns the door's outcome into the capability reply. A value
////    is converted to msgpack for the stub to decode, and a refusal travels
////    under one refusal code with the catalogue's own sentence.
////
//// ## Why the door speaks plain JSON
////
//// The doors are the same functions the operator-facing catalogue uses, and
//// they already validate their own arguments. This router therefore does not
//// restate any schema; it forwards the decoded map and lets the door refuse
//// a malformed field by name. That keeps one definition of each operation's
//// contract, in `client/evolution`, rather than one there and a second here.
////
//// ## What a candidate cannot do
////
//// A selected candidate program is vetted against an allowlist that excludes
//// `cap/evolution` (`client/codemode.seam_allowlist` is given a host with no
//// evolution door when candidates are vetted), so it cannot import the
//// stubs, and it cannot reach these names through a hand-built call either:
//// the router is installed only on the session's own executions.

import broker/framing
import codemode/internal/json_value
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, CapDenial,
}
import core/json.{type JsonValue}
import gleam/list

/// The code a refusal from the catalogue travels under. The message is the
/// catalogue's own sentence, so a program branches on the word before the
/// first colon (`Bounds`, `Authority`, `Stale`, `CoreChangeRequired`).
pub const refused_code = "evolution_refused"

/// What one door answered: the JSON result, or the refusal's sentence.
pub type Outcome =
  Result(JsonValue, String)

/// One operation, bound by the host to one execution. It takes the call's
/// ordinal, which is its index among this execution's calls of the same
/// capability, and its decoded arguments.
///
/// The ordinal is what lets the host keep two calls apart. Every call runs
/// under the execution's own operation and step, so without it a program that
/// fans two tests of one candidate out at once would run both under identical
/// coordinates and share a scratch directory.
pub type Operation =
  fn(Int, JsonValue) -> Outcome

/// The six operations, bound by the host to one execution.
pub type Door {
  Door(
    /// Captures authorized workspace source into an immutable candidate.
    propose: Operation,
    /// Runs author tests, or a paired prompt comparison, and retains evidence.
    test_candidate: Operation,
    /// Reads one bounded page of a candidate's or evidence's retained bytes.
    inspect: Operation,
    /// Lists selected candidates with their exact callable contracts.
    catalogue: Operation,
    /// Calls an exact discovered candidate under the caller's authority.
    invoke: Operation,
    /// Reads bounded excerpts of the session's own transcript.
    trace: Operation,
  )
}

/// The capability names this router answers.
pub const serviced_caps = [
  "evolution.propose", "evolution.test", "evolution.inspect",
  "evolution.catalogue", "evolution.invoke", "evolution.trace",
]

/// Lifetime ceilings on admissions per execution. A snapshot or a test can
/// take up to two minutes, so a program that loops over them is bounded
/// well below what the wall deadline would allow anyway.
///
/// ## Examples
///
/// ```gleam
/// list.length(evolution.ceilings()) == 6
/// ```
pub fn ceilings() -> List(satellite.CapCeiling) {
  list.map(
    [
      #("evolution.propose", 16),
      #("evolution.test", 16),
      #("evolution.inspect", 128),
      #("evolution.catalogue", 64),
      #("evolution.invoke", 64),
      #("evolution.trace", 8),
    ],
    fn(entry) {
      satellite.CapCeiling(
        cap: entry.0,
        admissions: entry.1,
        code: "admission_ceiling",
      )
    },
  )
}

/// Adds the six evolution operations to a host router. Unknown capabilities
/// remain the inner router's.
///
/// ## Examples
///
/// ```gleam
/// // evolution.routing(door, over: satellite.default_router)
/// ```
pub fn routing(door: Door, over router: CapRouter) -> CapRouter {
  fn(request: CapRequest) {
    case request.cap {
      "evolution.propose" -> plan(door.propose, request)
      "evolution.test" -> plan(door.test_candidate, request)
      "evolution.inspect" -> plan(door.inspect, request)
      "evolution.catalogue" -> plan(door.catalogue, request)
      "evolution.invoke" -> plan(door.invoke, request)
      "evolution.trace" -> plan(door.trace, request)
      _ -> router(request)
    }
  }
}

// The arguments are decoded once, here, so a malformed call is refused as
// the program's own repairable mistake before any door is entered.
fn plan(run: Operation, request: CapRequest) -> Result(CapPlan, CapDenial) {
  case json_value.to_json(request.args) {
    Error(reason) ->
      Error(CapDenial(
        code: "invalid_argument",
        message: "arguments must be JSON values: " <> reason,
      ))
    Ok(arguments) ->
      Ok(satellite.ServedHere(fn() { answer(run(request.ordinal, arguments)) }))
  }
}

fn answer(outcome: Outcome) -> framing.CapOutcome {
  case outcome {
    Ok(value) -> framing.CapOk(json_value.of_json(value))
    Error(sentence) -> framing.CapErr(code: refused_code, message: sentence)
  }
}
