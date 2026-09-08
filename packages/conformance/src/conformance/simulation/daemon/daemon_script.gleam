//// What a daemon run is asked to do, drawn from a seed.
////
//// The split between this module and `daemon_fault` is the one the session
//// runner already draws. A script is the semantic half: the workspaces, the
//// creation keys, and which of those keys are retried. It is what both runs
//// of a seed perform, and a difference in it is a difference in the answer.
//// A schedule is the transparent half: where the daemon dies. Neither run may
//// end anywhere the other did not.
////
//// The two are drawn from separate streams for the reason
//// `conformance/simulation/random` gives: adding a draw to one generator must
//// not shift the other's values, or a pinned corpus stops meaning what it
//// meant when it was pinned.
////
//// Every script reuses at least one key. That is the property the daemon
//// owns: a request key names a durable reservation, and a second creation
//// under it resumes that reservation rather than minting beside it. A script
//// with no reuse would still be a valid multi-session script, and it would
//// check nothing this layer exists for.

import conformance/simulation/random.{type Rng}
import gleam/int
import gleam/list
import gleam/string

/// The workspaces a script draws from. They are synthetic absolute paths
/// rather than real directories: the registry records a workspace as
/// owner-supplied metadata and never opens it, and a path that did exist
/// would make the rows depend on the machine's filesystem.
const workspaces = ["/simulation/workspace-a", "/simulation/workspace-b"]

/// One creation the script performs, in the order it performs them.
pub type Creation {
  Creation(
    /// The immutable request key. Two creations in one script never share
    /// one, so a reuse is always a retry rather than a collision.
    key: String,
    /// The workspace the owner names, which decides the domain record.
    workspace: String,
    /// The display label.
    name: String,
    /// The generator seed the first call mints from. A retry passes a
    /// different one on purpose.
    seed: Int,
  )
}

/// A whole script: the creations, in order, and the keys retried afterwards.
pub type Script {
  Script(creations: List(Creation), retries: List(String))
}

/// Draws a script: one or two workspaces, one to three creation keys spread
/// across them, and a non-empty set of keys retried afterwards.
///
/// ## Examples
///
/// ```gleam
/// // let #(script, rng) = daemon_script.generate(rng)
/// ```
pub fn generate(rng: Rng) -> #(Script, Rng) {
  let #(spread, rng) = random.int_between(rng, 1, 2)
  let #(count, rng) = random.weighted(rng, [#(2, 1), #(5, 2), #(3, 3)], 2)
  let available = list.take(workspaces, spread)
  let #(creations, rng) =
    random.list_of(rng, count, fn(rng) { draw(rng, available) })
  let creations = named(creations, 1, [])

  // At least one retry, because reuse is the whole claim. Drawing a count
  // rather than a subset keeps the retried keys a prefix of the creations,
  // which is enough variety and needs no second pass over the list.
  let #(retried, rng) = random.int_between(rng, 1, list.length(creations))
  let retries =
    list.take(creations, retried) |> list.map(fn(one: Creation) { one.key })
  #(Script(creations:, retries:), rng)
}

fn draw(rng: Rng, available: List(String)) -> #(Creation, Rng) {
  let #(workspace, rng) = random.pick(rng, available, "/simulation/workspace-a")
  let #(seed, rng) = random.int_between(rng, 1, 100_000)
  #(Creation(key: "", workspace:, name: "", seed:), rng)
}

// Keys and names are assigned after the draw rather than during it, so the
// generator spends no randomness on them and a script's identifiers stay
// readable in a failure line.
fn named(
  drawn: List(Creation),
  ordinal: Int,
  acc: List(Creation),
) -> List(Creation) {
  case drawn {
    [] -> list.reverse(acc)
    [one, ..rest] -> {
      let suffix = int.to_string(ordinal)
      let one =
        Creation(..one, key: "key-" <> suffix, name: "Session " <> suffix)
      named(rest, ordinal + 1, [one, ..acc])
    }
  }
}

/// The creations as `#(key, workspace)` in script order, which is what a
/// schedule is drawn over.
///
/// ## Examples
///
/// ```gleam
/// // daemon_fault.generate(rng, daemon_script.coordinates(script))
/// ```
pub fn coordinates(script: Script) -> List(#(String, String)) {
  list.map(script.creations, fn(one: Creation) { #(one.key, one.workspace) })
}

/// The keys a run retries after its last creation.
///
/// This is the script's own retry list and nothing else. A killed creation
/// needs no entry of its own: the run performs every creation the script
/// names on the restarted daemon, and the one the kill interrupted is among
/// them, so its reservation is resumed there rather than left `Reserved`
/// while the fault-free run's row reads `Saved`. Adding the killed key here
/// as well would only retry it a second time.
///
/// ## Examples
///
/// ```gleam
/// // daemon_script.retries(script)
/// ```
pub fn retries(script: Script) -> List(String) {
  script.retries
}

/// A one-line rendering, printed with a failing seed.
///
/// ## Examples
///
/// ```gleam
/// // daemon_script.describe(script)
/// ```
pub fn describe(script: Script) -> String {
  let created =
    list.map(script.creations, fn(one: Creation) {
      one.key <> "@" <> one.workspace
    })
  string.join(created, ", ") <> "; retry " <> string.join(script.retries, ", ")
}
