//// A plan is the frozen denominator of one run: every task, every arm and
//// every trial index that run owes, written down before any of them starts.
////
//// The plan, not the ledger, says how many rows there should be. A ledger
//// that is missing a row is then a visible hole rather than a smaller
//// experiment, and nothing downstream can make an arm look better by losing
//// the trials it failed. `rows` materialises the cells; `eval/ledger.reconcile`
//// holds the ledger to them.
////
//// A plan also records what ran it: the git commit of the harness and
//// whether the tree was clean. A dirty tree is fine for a quick look and
//// refused for a full run, because a result that cannot be reproduced from a
//// commit cannot be compared with another.
////
//// Like tasks, a plan is addressed by the digest of its canonical encoding
//// with the `id` blank, and `load` refuses a file whose content no longer
//// matches the id it carries.

import client/mcp
import core/json.{type JsonValue}
import eval/wire
import gleam/int
import gleam/list
import gleam/result
import simplifile

/// One frozen run.
pub type Plan {
  Plan(
    /// SHA-256 hex of the canonical encoding with this field blank.
    id: String,
    /// The tasks measured, by task id, unique.
    task_ids: List(String),
    /// The arms compared, by arm id, unique.
    arm_ids: List(String),
    /// Trials per task-and-arm cell, the K of the design.
    trials_per_cell: Int,
    /// Whether model traffic is replayed from a tape or live.
    lane: Lane,
    /// How much of the instrument's rigour this run claims.
    profile: Profile,
    /// The salt `eval/split.assign` hashes families with.
    split_salt: String,
    /// What a trial and the run as a whole may spend.
    budgets: Budgets,
    /// What ran the plan.
    harness: Harness,
  )
}

/// Where model responses come from.
pub type Lane {
  /// From a recorded tape: free, deterministic, and it measures the harness.
  Replay

  /// From a provider: costs money and measures the model as well.
  Live
}

/// How much of the instrument's rigour a run claims.
pub type Profile {
  /// A fast look; a dirty tree is tolerated.
  Quick

  /// A run whose result may be compared with others; a dirty tree is refused.
  Full
}

/// The spending ceilings of a run.
pub type Budgets {
  Budgets(
    /// Provider requests one trial may make.
    max_requests_per_trial: Int,
    /// Dollars the whole run may spend.
    max_dollars: Float,
    /// Wall-clock milliseconds one trial may take.
    wall_ms_per_trial: Int,
    /// Trials in flight at once.
    concurrency: Int,
  )
}

/// What produced the run.
pub type Harness {
  Harness(
    /// The 40-digit git commit of the harness source.
    git_commit: String,
    /// Whether the tree had uncommitted changes.
    posture: Posture,
  )
}

/// Whether the harness tree matched its commit.
pub type Posture {
  /// The tree is exactly the commit.
  Clean

  /// The tree carries uncommitted changes.
  Dirty
}

/// The key a trial is paired by within a plan.
pub type RowKey {
  RowKey(
    /// The task id.
    task: String,
    /// The arm id.
    arm: String,
    /// The trial index, zero-based, below `trials_per_cell`.
    index: Int,
  )
}

/// The plan encoding version.
pub const version = 2

/// The canonical encoding of a plan.
///
/// ## Examples
///
/// ```gleam
/// // json.to_string(plan.to_json(p)) starts with {"arm_ids":…
/// ```
///
pub fn to_json(plan: Plan) -> JsonValue {
  json.canonical(
    json.Object([
      #("v", json.Int(version)),
      #("id", json.String(plan.id)),
      #("task_ids", strings_json(plan.task_ids)),
      #("arm_ids", strings_json(plan.arm_ids)),
      #("trials_per_cell", json.Int(plan.trials_per_cell)),
      #("lane", json.String(lane_name(plan.lane))),
      #("profile", json.String(profile_name(plan.profile))),
      #("split_salt", json.String(plan.split_salt)),
      #("budgets", budgets_json(plan.budgets)),
      #("harness", harness_json(plan.harness)),
    ]),
  )
}

/// Returns the plan with `id` set to the digest of its canonical encoding
/// taken with the id blank.
///
/// ## Examples
///
/// ```gleam
/// // plan.mint(plan.mint(p)) == plan.mint(p)
/// ```
///
pub fn mint(plan: Plan) -> Plan {
  Plan(..plan, id: digest(plan))
}

/// Refuses a plan whose id is not the digest of its content.
///
/// ## Examples
///
/// ```gleam
/// // plan.verify_id(plan.mint(p)) == Ok(plan.mint(p))
/// ```
///
pub fn verify_id(plan: Plan) -> Result(Plan, String) {
  let actual = digest(plan)

  // A mismatch means the plan was edited after minting; both digests are named
  // so the editor can re-mint.
  case actual == plan.id {
    True -> Ok(plan)
    False ->
      Error(
        "plan content changed: id "
        <> plan.id
        <> " but content digests to "
        <> actual,
      )
  }
}

/// Checks the invariants a plan must hold whatever produced it: nonempty
/// unique id lists, positive bounded budgets, a 40-digit commit, and no
/// dirty tree under the `Full` profile. `decode` runs it, and a caller
/// building a plan in memory should too, before minting.
///
/// ## Examples
///
/// ```gleam
/// // plan.check(full_plan_with_dirty_harness) == Error("a full plan refuses a dirty tree: …")
/// ```
///
pub fn check(plan: Plan) -> Result(Plan, String) {
  use Nil <- result.try(require(
    plan.task_ids != [] && distinct(plan.task_ids),
    "task_ids must be nonempty and unique",
  ))
  use Nil <- result.try(require(
    plan.arm_ids != [] && distinct(plan.arm_ids),
    "arm_ids must be nonempty and unique",
  ))
  use Nil <- result.try(require(
    plan.trials_per_cell >= 1 && plan.trials_per_cell <= 1000,
    "trials_per_cell must be between 1 and 1000",
  ))
  use Nil <- result.try(check_budgets(plan.budgets))
  use Nil <- result.try(require(
    wire.is_hex(plan.harness.git_commit, 40),
    "harness commit must be 40-digit lowercase hex",
  ))

  // Only the Full profile on a Dirty tree is refused; every other pairing is a
  // run someone may legitimately want.
  case plan.profile, plan.harness.posture {
    Full, Dirty ->
      Error(
        "a full plan refuses a dirty tree: commit or stash, then rerun, or use the quick profile",
      )
    Full, Clean | Quick, Clean | Quick, Dirty -> Ok(plan)
  }
}

/// Every `(task, arm, index)` the plan owes, task-major, then arm, then
/// index. This list is the denominator: its length is
/// tasks times arms times K, whatever any ledger holds.
///
/// ## Examples
///
/// ```gleam
/// // list.length(plan.rows(p)) == tasks * arms * p.trials_per_cell
/// ```
///
pub fn rows(plan: Plan) -> List(RowKey) {
  use task <- list.flat_map(plan.task_ids)
  use arm <- list.flat_map(plan.arm_ids)
  use _, index <- list.index_map(list.repeat(Nil, plan.trials_per_cell))

  RowKey(task:, arm:, index:)
}

/// Renders a row key as `task/arm/index` for messages.
///
/// ## Examples
///
/// ```gleam
/// assert plan.key_to_string(plan.RowKey("t", "a", 2)) == "t/a/2"
/// ```
///
pub fn key_to_string(key: RowKey) -> String {
  key.task <> "/" <> key.arm <> "/" <> int.to_string(key.index)
}

/// Decodes and checks a plan. Total.
///
/// ## Examples
///
/// ```gleam
/// // plan.decode(plan.to_json(p)) == Ok(p) for a valid p
/// ```
///
pub fn decode(value: JsonValue) -> Result(Plan, String) {
  use fields <- result.try(wire.object(value, plan_keys))
  use v <- result.try(wire.int(fields, "v"))
  use Nil <- result.try(require(v == version, "unsupported plan version"))
  use id <- result.try(wire.text(fields, "id"))
  use Nil <- result.try(require(id == "" || wire.is_hex(id, 64), "bad plan id"))
  use task_ids <- result.try(wire.strings(fields, "task_ids"))
  use arm_ids <- result.try(wire.strings(fields, "arm_ids"))
  use trials_per_cell <- result.try(wire.int(fields, "trials_per_cell"))
  use lane <- result.try(wire.text(fields, "lane") |> result.try(decode_lane))
  use profile <- result.try(
    wire.text(fields, "profile") |> result.try(decode_profile),
  )
  use split_salt <- result.try(wire.text(fields, "split_salt"))
  use budgets <- result.try(
    wire.required(fields, "budgets") |> result.try(decode_budgets),
  )
  use harness <- result.try(
    wire.required(fields, "harness") |> result.try(decode_harness),
  )

  check(Plan(
    id:,
    task_ids:,
    arm_ids:,
    trials_per_cell:,
    lane:,
    profile:,
    split_salt:,
    budgets:,
    harness:,
  ))
}

/// Reads a plan file, decodes it and verifies its digest.
///
/// ## Examples
///
/// ```gleam
/// // plan.load("runs/<plan id>/plan.json")
/// ```
///
pub fn load(path: String) -> Result(Plan, String) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(reason) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(reason)
    }),
  )
  use value <- result.try(
    json.parse(body)
    |> result.map_error(fn(_report) { path <> ": not valid JSON" }),
  )
  use plan <- result.try(decode(value))

  verify_id(plan)
}

const plan_keys = [
  "v", "id", "task_ids", "arm_ids", "trials_per_cell", "lane", "profile",
  "split_salt", "budgets", "harness",
]

fn digest(plan: Plan) -> String {
  Plan(..plan, id: "")
  |> to_json
  |> json.to_string
  |> mcp.sha256_hex
}

fn require(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn distinct(items: List(String)) -> Bool {
  list.length(list.unique(items)) == list.length(items)
}

/// Refuses non-positive limits and a concurrency beyond 256, which no host here could honour.
fn check_budgets(budgets: Budgets) -> Result(Nil, String) {
  require(
    budgets.max_requests_per_trial >= 1
      && budgets.max_dollars >=. 0.0
      && budgets.wall_ms_per_trial >= 1
      && budgets.concurrency >= 1
      && budgets.concurrency <= 256,
    "budgets must be positive and concurrency at most 256",
  )
}

fn strings_json(items: List(String)) -> JsonValue {
  json.Array(list.map(items, json.String))
}

fn lane_name(lane: Lane) -> String {
  case lane {
    Replay -> "replay"
    Live -> "live"
  }
}

/// Parses a lane's wire spelling.
fn decode_lane(name: String) -> Result(Lane, String) {
  case name {
    "replay" -> Ok(Replay)
    "live" -> Ok(Live)
    other -> Error("unknown lane \"" <> other <> "\"")
  }
}

fn profile_name(profile: Profile) -> String {
  case profile {
    Quick -> "quick"
    Full -> "full"
  }
}

/// Parses a profile's wire spelling.
fn decode_profile(name: String) -> Result(Profile, String) {
  case name {
    "quick" -> Ok(Quick)
    "full" -> Ok(Full)
    other -> Error("unknown profile \"" <> other <> "\"")
  }
}

/// Encodes the spending ceilings of a run.
fn budgets_json(budgets: Budgets) -> JsonValue {
  json.Object([
    #("max_requests_per_trial", json.Int(budgets.max_requests_per_trial)),
    #("max_dollars", json.Float(budgets.max_dollars)),
    #("wall_ms_per_trial", json.Int(budgets.wall_ms_per_trial)),
    #("concurrency", json.Int(budgets.concurrency)),
  ])
}

/// Decodes the spending ceilings; `check` bounds them afterwards, so a decoded value is always checked.
fn decode_budgets(value: JsonValue) -> Result(Budgets, String) {
  use fields <- result.try(
    wire.object(value, [
      "max_requests_per_trial", "max_dollars", "wall_ms_per_trial",
      "concurrency",
    ]),
  )
  use max_requests_per_trial <- result.try(wire.int(
    fields,
    "max_requests_per_trial",
  ))
  use max_dollars <- result.try(wire.number(fields, "max_dollars"))
  use wall_ms_per_trial <- result.try(wire.int(fields, "wall_ms_per_trial"))
  use concurrency <- result.try(wire.int(fields, "concurrency"))

  Ok(Budgets(
    max_requests_per_trial:,
    max_dollars:,
    wall_ms_per_trial:,
    concurrency:,
  ))
}

fn harness_json(harness: Harness) -> JsonValue {
  json.Object([
    #("git_commit", json.String(harness.git_commit)),
    #("posture", json.String(posture_name(harness.posture))),
  ])
}

fn posture_name(posture: Posture) -> String {
  case posture {
    Clean -> "clean"
    Dirty -> "dirty"
  }
}

/// Decodes what ran the plan: a commit and a posture.
fn decode_harness(value: JsonValue) -> Result(Harness, String) {
  use fields <- result.try(wire.object(value, ["git_commit", "posture"]))
  use git_commit <- result.try(wire.text(fields, "git_commit"))
  use posture <- result.try(
    wire.text(fields, "posture") |> result.try(decode_posture),
  )

  Ok(Harness(git_commit:, posture:))
}

/// Parses a harness posture's wire spelling.
fn decode_posture(name: String) -> Result(Posture, String) {
  case name {
    "clean" -> Ok(Clean)
    "dirty" -> Ok(Dirty)
    other -> Error("unknown posture \"" <> other <> "\"")
  }
}
