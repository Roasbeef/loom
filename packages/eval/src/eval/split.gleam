//// Which third of the task pool a task belongs to, and the one refusal that
//// keeps the last third unspent.
////
//// A benchmark that is tuned against and then reported on measures how well
//// the tuner memorised it. The split exists so that one slice of tasks is
//// never shown to anything that learns. It is assigned by hash, not by
//// choice: a person choosing which tasks are held out would, with the best
//// will, choose the ones they already know the answers to.
////
//// Assignment is by task family rather than by task. Two commits that touch
//// the same module are near-duplicates, and one in `Tune` with its sibling
//// in `Holdout` would leak the answer across the wall. Hashing the family
//// puts them on the same side.
////
//// The seal is the refusal in `admissible`: the door through which task ids
//// enter the governed comparison path never opens for `Holdout`. This module
//// holds the pure part; the door itself belongs to a later slice.

import client/mcp
import eval/task.{type Task}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The three sides of the wall.
pub type Split {
  /// The slice an optimiser may learn from: six tenths.
  Tune

  /// The slice a candidate is selected on: two tenths.
  Validate

  /// The slice nothing learns from or is admitted against: two tenths.
  Holdout
}

/// The prefix of a tag that names a task's family.
const family_tag = "family:"

/// Assigns a family to a split: SHA-256 of the salt followed by the family,
/// the first four bytes read as a big-endian unsigned integer, modulo ten,
/// with 0 to 5 `Tune`, 6 and 7 `Validate`, 8 and 9 `Holdout`. Four bytes
/// rather than one because a single byte modulo ten is biased (residues 0 to
/// 5 occur 26 times in 256, the rest 25), which would shave the holdout.
/// The salt belongs to the plan, so re-salting is a new plan.
///
/// ## Examples
///
/// ```gleam
/// // split.assign("salt", "packages/core/json") is one fixed value forever
/// ```
///
pub fn assign(salt: String, family: String) -> Split {
  let digest = mcp.sha256_hex(salt <> family)
  let word =
    digest
    |> string.slice(0, 8)
    |> int.base_parse(16)
    |> result.unwrap(0)

  // The decile of the word picks the split: six tenths Tune, two Validate,
  // two Holdout.
  case word % 10 {
    0 | 1 | 2 | 3 | 4 | 5 -> Tune
    6 | 7 -> Validate
    _ -> Holdout
  }
}

/// The family a task's split is assigned by. A task does not carry the paths
/// its fix touched, so a miner records the family as a `family:<value>` tag,
/// for example `family:packages/core/json`. When several are present the
/// least one wins, so the answer does not depend on tag order. A task with
/// no such tag is its own family, keyed by its `name`: unlike the id, the
/// name survives the edit that "fixes" a task by minting a new one, so the
/// replacement stays on the same side of the wall as the task it replaces.
///
/// ## Examples
///
/// ```gleam
/// // split.family(task with tag "family:packages/core/json") == "packages/core/json"
/// ```
///
pub fn family(task: Task) -> String {
  let tagged =
    task.tags
    |> list.filter_map(fn(tag) {
      case string.starts_with(tag, family_tag) {
        True -> Ok(string.drop_start(tag, string.length(family_tag)))
        False -> Error(Nil)
      }
    })
    |> list.filter(fn(value) { value != "" })
    |> list.sort(string.compare)

  // A blank family tag would pool unrelated tasks, so it counts as absent.
  case tagged {
    [first, ..] -> first
    [] -> task.name
  }
}

/// Lets `Tune` and `Validate` through and refuses `Holdout`. Every path that
/// admits task ids to a place an optimiser can name them calls this first.
///
/// ## Examples
///
/// ```gleam
/// assert split.admissible(split.Tune) == Ok(split.Tune)
/// ```
///
pub fn admissible(split: Split) -> Result(Split, String) {
  case split {
    Tune | Validate -> Ok(split)
    Holdout ->
      Error(
        "the holdout split is never admitted; it runs only as a holdout run",
      )
  }
}
